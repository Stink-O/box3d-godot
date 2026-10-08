// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

#include "sat_benchmark.h"

#include "utils.h"

#include "box3d/constants.h"
#include "box3d/math_functions.h"

#include "manifold.h"
#include "simd.h"

#include <stdlib.h>

const char* GetSatHullName( SatHullType type )
{
	switch ( type )
	{
		case satHull_complex:
			return "complex";
		case satHull_rock:
			return "rock";
		case satHull_cylinder:
			return "cylinder";
		default:
			return "unknown";
	}
}

static b3HullData* CreateSatHull( SatHullType type )
{
	switch ( type )
	{
		case satHull_complex:
			return b3CreateComplexHull( 0.5f );
		case satHull_rock:
			return b3CreateRock( 0.5f );
		case satHull_cylinder:
			return b3CreateCylinder( 1.0f, 0.1f, -0.5f, 32 );
		default:
			B3_ASSERT( false );
			return NULL;
	}
}

static float GetBoundingRadius( const b3HullData* hull )
{
	b3Vec3 center = b3AABB_Center( hull->aabb );
	b3Vec3 extents = b3AABB_Extents( hull->aabb );
	return b3Length( center ) + b3Length( extents );
}

SatBenchmarkData* CreateSatBenchmark( SatHullType typeA, SatHullType typeB )
{
	SatBenchmarkData* data = calloc( 1, sizeof( SatBenchmarkData ) );
	data->hullA = CreateSatHull( typeA );
	data->hullB = CreateSatHull( typeB );
	data->innerRadiusA = data->hullA->innerRadius;
	data->innerRadiusB = data->hullB->innerRadius;

	const b3HullData* hullA = data->hullA;
	const b3HullData* hullB = data->hullB;

	b3DistanceInput input = {
		.proxyA = { b3GetHullPoints( hullA ), hullA->vertexCount, 0.0f },
		.proxyB = { b3GetHullPoints( hullB ), hullB->vertexCount, 0.0f },
		.useRadii = false,
	};

	float target = 0.5f * B3_SPECULATIVE_DISTANCE;
	float tolerance = 0.01f * target;
	float reach = GetBoundingRadius( hullA ) + GetBoundingRadius( hullB ) + 0.5f;

	data->targetDistance = target;
	data->maxPlacementError = 0.0f;

	uint32_t savedSeed = g_randomSeed;
	g_randomSeed = 1234;

	for ( int i = 0; i < SAT_PAIR_COUNT; ++i )
	{
		b3Quat q = RandomQuat();
		b3Vec3 direction = b3RotateVector( RandomQuat(), b3Vec3_axisX );
		b3Transform transform = { b3MulSV( reach, direction ), q };

		// Newton iteration, the gradient of distance with respect to the position of B is the
		// normal. Distance is 1-Lipschitz so each step lands at or above the target and never overlaps.
		b3SimplexCache cache = { 0 };
		float error = 0.0f;
		for ( int iteration = 0; iteration < 20; ++iteration )
		{
			input.transform = transform;
			b3DistanceOutput output = b3ShapeDistance( &input, &cache, NULL, 0 );
			error = output.distance - target;
			if ( b3AbsFloat( error ) < tolerance )
			{
				break;
			}

			transform.p = b3MulSub( transform.p, error, output.normal );
		}

		data->transforms[i] = transform;
		data->caches[i] = cache;
		data->maxPlacementError = b3MaxFloat( data->maxPlacementError, b3AbsFloat( error ) );
	}

	g_randomSeed = savedSeed;

	return data;
}

void DestroySatBenchmark( SatBenchmarkData* data )
{
	b3DestroyHull( data->hullA );
	b3DestroyHull( data->hullB );
	free( data );
}

void EnableSatInscribedSphere( SatBenchmarkData* data, bool flag )
{
	// A hugely negative radius drives the SAT upper bound so high that no candidate is skipped.
	// It must stay finite or the bound becomes NaN.
	float disabledRadius = -B3_HUGE;
	data->hullA->innerRadius = flag ? data->innerRadiusA : disabledRadius;
	data->hullB->innerRadius = flag ? data->innerRadiusB : disabledRadius;
}

SatBenchmarkResult RunSatBenchmark( const SatBenchmarkData* data, int repeatCount, bool warmStartDistance )
{
	const b3HullData* hullA = data->hullA;
	const b3HullData* hullB = data->hullB;

	b3DistanceInput input = {
		.proxyA = { b3GetHullPoints( hullA ), hullA->vertexCount, 0.0f },
		.proxyB = { b3GetHullPoints( hullB ), hullB->vertexCount, 0.0f },
		.useRadii = false,
	};

	float distanceSum = 0.0f;
	int iterationSum = 0;

	uint64_t ticks = b3GetTicks();

	for ( int repeat = 0; repeat < repeatCount; ++repeat )
	{
		for ( int i = 0; i < SAT_PAIR_COUNT; ++i )
		{
			input.transform = data->transforms[i];
			b3SimplexCache cache = warmStartDistance ? data->caches[i] : (b3SimplexCache){ 0 };
			b3DistanceOutput output = b3ShapeDistance( &input, &cache, NULL, 0 );
			distanceSum += output.distance;
			iterationSum += output.iterations;
		}
	}

	float distanceMs = b3GetMillisecondsAndReset( &ticks );

	float separationSum = 0.0f;
	int earlyReturnCount = 0;

	for ( int repeat = 0; repeat < repeatCount; ++repeat )
	{
		for ( int i = 0; i < SAT_PAIR_COUNT; ++i )
		{
			// Early return enabled to match the manifold path. The placement keeps it from firing.
			b3AxisQuery query = b3ComputeSeparatingAxis( hullA, hullB, data->transforms[i], true );
			b3SeparatingAxis axis = b3GetBestAxis( &query );
			separationSum += axis.separation;
			earlyReturnCount += query.separatedFeature != b3_invalidAxis ? 1 : 0;
		}
	}

	float satMs = b3GetMilliseconds( ticks );

	int queryCount = repeatCount * SAT_PAIR_COUNT;
	SatBenchmarkResult result = {
		.distanceMs = distanceMs,
		.satMs = satMs,
		.queryCount = queryCount,
		.averageDistance = distanceSum / queryCount,
		.averageSeparation = separationSum / queryCount,
		.averageIterations = (float)iterationSum / queryCount,
		.earlyReturnCount = earlyReturnCount,
	};
	return result;
}

void SetSimdWidth( int width )
{
	b3SetSIMDWidth( width );
}

int GetSimdWidth( void )
{
	return b3GetSIMDWidth();
}

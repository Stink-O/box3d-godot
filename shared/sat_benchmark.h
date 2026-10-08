// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT
#pragma once

#include "box3d/collision.h"

#include <stdbool.h>

// Compares GJK (b3ShapeDistance) against SAT (b3ComputeSeparatingAxis) on hull pairs held
// inside the speculative margin, so neither query can exit early. SAT is internal, so this
// is only available when Box3D is linked statically, see BOX3D_INTERNAL_BENCHMARKS.

#ifdef __cplusplus
extern "C"
{
#endif

typedef enum SatHullType
{
	satHull_complex,
	satHull_rock,
	satHull_cylinder,
	satHull_count
} SatHullType;

#define SAT_PAIR_COUNT 1000

typedef struct SatBenchmarkData
{
	b3HullData* hullA;
	b3HullData* hullB;
	float innerRadiusA;
	float innerRadiusB;

	// Hull A sits at the origin so these are the poses of B in the frame of A
	b3Transform transforms[SAT_PAIR_COUNT];

	// Converged GJK caches for a warm started distance query
	b3SimplexCache caches[SAT_PAIR_COUNT];

	float targetDistance;
	float maxPlacementError;
} SatBenchmarkData;

typedef struct SatBenchmarkResult
{
	float distanceMs;
	float satMs;
	int queryCount;
	float averageDistance;
	float averageSeparation;
	float averageIterations;

	// Should be zero, otherwise the placement let SAT exit early
	int earlyReturnCount;
} SatBenchmarkResult;

const char* GetSatHullName( SatHullType type );

SatBenchmarkData* CreateSatBenchmark( SatHullType typeA, SatHullType typeB );
void DestroySatBenchmark( SatBenchmarkData* data );

// Disabling the inscribed sphere bound makes SAT evaluate every face and edge candidate
void EnableSatInscribedSphere( SatBenchmarkData* data, bool flag );

SatBenchmarkResult RunSatBenchmark( const SatBenchmarkData* data, int repeatCount, bool warmStartDistance );

void SetSimdWidth( int width );
int GetSimdWidth( void );

#ifdef __cplusplus
}
#endif

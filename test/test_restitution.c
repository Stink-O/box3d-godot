// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

#include "body.h"
#include "physics_world.h"
#include "recording.h"
#include "test_macros.h"

#include "box3d/box3d.h"
#include "box3d/collision.h"
#include "box3d/math_functions.h"

#include <float.h>
#include <math.h>
#include <stdio.h>

#define TIME_STEP ( 1.0f / 60.0f )
#define SUB_STEP_COUNT 4

// A flat landing converges its Gauss-Seidel coupling in four stage iterations and the default is two,
// so the tests that read the coefficient or the spin of a flat landing pin the count
#define RESTITUTION_ITERATIONS 4

// Impact speed shared by every scenario that measures a coefficient. Well above the default
// restitution threshold so the bounce is always armed.
#define IMPACT_SPEED 5.0f

// Each subtest prints all of its measurements before asserting, and the battery runs every subtest
// so one bad scenario does not hide the rest.
#define RUN_MEASUREMENT( T )                                                                                                     \
	do                                                                                                                           \
	{                                                                                                                            \
		if ( T() != 0 )                                                                                                          \
		{                                                                                                                        \
			printf( "  subtest failed: " #T "\n" );                                                                              \
			failureCount += 1;                                                                                                   \
		}                                                                                                                        \
		else                                                                                                                     \
		{                                                                                                                        \
			printf( "  subtest passed: " #T "\n" );                                                                              \
		}                                                                                                                        \
	}                                                                                                                            \
	while ( false )

static b3WorldId MakeWorld( float gravityY )
{
	b3WorldDef worldDef = b3DefaultWorldDef();
	worldDef.gravity = (b3Vec3){ 0.0f, gravityY, 0.0f };
	worldDef.enableSleep = false;
	return b3CreateWorld( &worldDef );
}

static b3WorldId MakeWorldIterations( float gravityY, int restitutionIterations )
{
	b3WorldDef worldDef = b3DefaultWorldDef();
	worldDef.gravity = (b3Vec3){ 0.0f, gravityY, 0.0f };
	worldDef.enableSleep = false;
	worldDef.restitutionIterations = restitutionIterations;
	return b3CreateWorld( &worldDef );
}

// Ground with its top surface at y = 0
static void MakeGround( b3WorldId worldId, float restitution )
{
	b3BodyDef bodyDef = b3DefaultBodyDef();
	bodyDef.position = (b3Pos){ 0.0f, -1.0f, 0.0f };
	b3BodyId groundId = b3CreateBody( worldId, &bodyDef );

	b3ShapeDef shapeDef = b3DefaultShapeDef();
	shapeDef.baseMaterial.friction = 0.0f;
	shapeDef.baseMaterial.restitution = restitution;
	b3BoxHull box = b3MakeBoxHull( 40.0f, 1.0f, 40.0f );
	b3CreateHullShape( groundId, &shapeDef, &box.base );
}

static b3BodyId MakeBall( b3WorldId worldId, float x, float y, float velocityY, float restitution )
{
	b3BodyDef bodyDef = b3DefaultBodyDef();
	bodyDef.type = b3_dynamicBody;
	bodyDef.position = (b3Pos){ x, y, 0.0f };
	bodyDef.linearVelocity = (b3Vec3){ 0.0f, velocityY, 0.0f };
	b3BodyId bodyId = b3CreateBody( worldId, &bodyDef );

	b3ShapeDef shapeDef = b3DefaultShapeDef();
	shapeDef.baseMaterial.friction = 0.0f;
	shapeDef.baseMaterial.restitution = restitution;
	b3Sphere sphere = { { 0.0f, 0.0f, 0.0f }, 0.5f };
	b3CreateSphereShape( bodyId, &shapeDef, &sphere );
	return bodyId;
}

// Two free spheres closing head on with no gravity. The coefficient is the ratio of relative normal
// speeds at the contact, which is the mass independent definition.
static float MeasureHeadOn( float restitution, float densityB, float* momentumError )
{
	b3WorldId worldId = MakeWorld( 0.0f );

	b3Sphere sphere = { { 0.0f, 0.0f, 0.0f }, 0.5f };
	b3ShapeDef shapeDef = b3DefaultShapeDef();
	shapeDef.density = 1.0f;
	shapeDef.baseMaterial.friction = 0.0f;
	shapeDef.baseMaterial.restitution = restitution;

	b3BodyDef bodyDef = b3DefaultBodyDef();
	bodyDef.type = b3_dynamicBody;
	bodyDef.position = (b3Pos){ -1.0f, 0.0f, 0.0f };
	bodyDef.linearVelocity = (b3Vec3){ 0.5f * IMPACT_SPEED, 0.0f, 0.0f };
	b3BodyId idA = b3CreateBody( worldId, &bodyDef );
	b3CreateSphereShape( idA, &shapeDef, &sphere );

	bodyDef.position = (b3Pos){ 1.0f, 0.0f, 0.0f };
	bodyDef.linearVelocity = (b3Vec3){ -0.5f * IMPACT_SPEED, 0.0f, 0.0f };
	b3BodyId idB = b3CreateBody( worldId, &bodyDef );
	shapeDef.density = densityB;
	b3CreateSphereShape( idB, &shapeDef, &sphere );

	float massA = b3Body_GetMass( idA );
	float massB = b3Body_GetMass( idB );
	float momentum0 = massA * b3Body_GetLinearVelocity( idA ).x + massB * b3Body_GetLinearVelocity( idB ).x;

	for ( int i = 0; i < 120; ++i )
	{
		b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );
	}

	float vA = b3Body_GetLinearVelocity( idA ).x;
	float vB = b3Body_GetLinearVelocity( idB ).x;
	float momentum1 = massA * vA + massB * vB;

	b3DestroyWorld( worldId );

	*momentumError = ( momentum1 - momentum0 ) / ( massA + massB );
	return ( vB - vA ) / IMPACT_SPEED;
}

// Ball driven into static ground with no gravity so the measurement carries no gravity bias. The
// gap shifts where inside the time step the impact lands.
static float MeasureGroundBounce( float restitution, float gap )
{
	b3WorldId worldId = MakeWorld( 0.0f );
	MakeGround( worldId, 0.0f );

	b3BodyId ballId = MakeBall( worldId, 0.0f, 0.5f + gap, -IMPACT_SPEED, restitution );

	for ( int i = 0; i < 60; ++i )
	{
		b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );
	}

	float speed = b3Body_GetLinearVelocity( ballId ).y;
	b3DestroyWorld( worldId );
	return speed / IMPACT_SPEED;
}

// Impactor driven onto a column of resting balls pinned against the ground. The support balls are
// dead so only the top contact can bounce. A supported target has infinite effective mass along the
// normal, so the coefficient must not depend on the column height.
static float MeasureSupportedBounce( float restitution, int supportCount, bool propagate )
{
	b3WorldDef worldDef = b3DefaultWorldDef();
	worldDef.gravity = b3Vec3_zero;
	worldDef.enableSleep = false;
	worldDef.enableRestitutionPropagation = propagate;
	worldDef.restitutionIterations = RESTITUTION_ITERATIONS;
	b3WorldId worldId = b3CreateWorld( &worldDef );
	MakeGround( worldId, 0.0f );

	for ( int i = 0; i < supportCount; ++i )
	{
		MakeBall( worldId, 0.0f, 0.5f + 1.0f * i, 0.0f, 0.0f );
	}

	float y = 0.5f + 1.0f * supportCount + 0.5f * IMPACT_SPEED * TIME_STEP;
	b3BodyId ballId = MakeBall( worldId, 0.0f, y, -IMPACT_SPEED, restitution );

	for ( int i = 0; i < 60; ++i )
	{
		b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );
	}

	float speed = b3Body_GetLinearVelocity( ballId ).y;
	b3DestroyWorld( worldId );
	return speed / IMPACT_SPEED;
}

// Flat box landing on all four corners at once with no gravity
static float MeasureFlatBounce( float restitution, int subStepCount, float* spin )
{
	b3WorldId worldId = MakeWorldIterations( 0.0f, RESTITUTION_ITERATIONS );
	MakeGround( worldId, 0.0f );

	b3BodyDef bodyDef = b3DefaultBodyDef();
	bodyDef.type = b3_dynamicBody;
	bodyDef.position = (b3Pos){ 0.0f, 0.25f + 0.5f * IMPACT_SPEED * TIME_STEP, 0.0f };
	bodyDef.linearVelocity = (b3Vec3){ 0.0f, -IMPACT_SPEED, 0.0f };
	b3BodyId boxId = b3CreateBody( worldId, &bodyDef );

	b3ShapeDef shapeDef = b3DefaultShapeDef();
	shapeDef.density = 1.0f;
	shapeDef.baseMaterial.friction = 0.0f;
	shapeDef.baseMaterial.restitution = restitution;
	b3BoxHull box = b3MakeBoxHull( 1.0f, 0.25f, 1.0f );
	b3CreateHullShape( boxId, &shapeDef, &box.base );

	for ( int i = 0; i < 60; ++i )
	{
		b3World_Step( worldId, TIME_STEP, subStepCount );
	}

	float speed = b3Body_GetLinearVelocity( boxId ).y;
	*spin = b3Length( b3Body_GetAngularVelocity( boxId ) );
	b3DestroyWorld( worldId );
	return speed / IMPACT_SPEED;
}

// Perfectly elastic ball dropped under gravity
static int MeasureDrop( float dropHeight, float* apexes, int capacity )
{
	b3WorldId worldId = MakeWorld( -10.0f );
	MakeGround( worldId, 0.0f );

	b3BodyId ballId = MakeBall( worldId, 0.0f, dropHeight, 0.0f, 1.0f );

	int apexCount = 0;
	float previousSpeed = 0.0f;

	for ( int i = 0; i < 4000 && apexCount < capacity; ++i )
	{
		b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );

		float speed = b3Body_GetLinearVelocity( ballId ).y;
		if ( previousSpeed > 0.0f && speed <= 0.0f )
		{
			apexes[apexCount] = (float)b3Body_GetPosition( ballId ).y;
			apexCount += 1;
		}
		previousSpeed = speed;
	}

	b3DestroyWorld( worldId );
	return apexCount;
}

static int HeadOnTest( void )
{
	static const float restitutions[] = { 0.0f, 0.25f, 0.5f, 0.75f, 1.0f };
	static const float densities[] = { 1.0f, 10.0f, 100.0f };
	const float tolerance = 0.02f;

	int failed = 0;

	for ( int i = 0; i < ARRAY_COUNT( densities ); ++i )
	{
		float worstError = 0.0f;
		float worstMomentum = 0.0f;

		for ( int j = 0; j < ARRAY_COUNT( restitutions ); ++j )
		{
			float momentumError = 0.0f;
			float measured = MeasureHeadOn( restitutions[j], densities[i], &momentumError );

			float error = b3AbsFloat( measured - restitutions[j] );
			if ( error > worstError )
			{
				worstError = error;
			}

			if ( b3AbsFloat( momentumError ) > b3AbsFloat( worstMomentum ) )
			{
				worstMomentum = momentumError;
			}

			if ( error > tolerance )
			{
				printf( "    head on density %.0f e %.2f -> %.4f\n", densities[i], restitutions[j], measured );
				failed = 1;
			}
		}

		printf( "    head on density %6.1f worst error %.4f momentum drift %.2e\n", densities[i], worstError, worstMomentum );

		if ( b3AbsFloat( worstMomentum ) > 1.0e-4f )
		{
			failed = 1;
		}
	}

	return failed;
}

static int PhaseTest( void )
{
	static const float restitutions[] = { 0.25f, 0.5f, 0.9f };
	const int sampleCount = 16;
	const float tolerance = 0.05f;

	int failed = 0;

	for ( int j = 0; j < ARRAY_COUNT( restitutions ); ++j )
	{
		float minimum = FLT_MAX;
		float maximum = -FLT_MAX;
		float sum = 0.0f;

		for ( int i = 0; i < sampleCount; ++i )
		{
			// Sweep the gap across one step of travel so the impact lands at every phase
			float gap = ( (float)i / (float)sampleCount ) * IMPACT_SPEED * TIME_STEP;
			float measured = MeasureGroundBounce( restitutions[j], gap );
			minimum = b3MinFloat( minimum, measured );
			maximum = b3MaxFloat( maximum, measured );
			sum += measured;
		}

		float mean = sum / sampleCount;
		float spread = maximum - minimum;
		printf( "    phase e %.2f -> mean %.4f spread %.4f [%.4f, %.4f]\n", restitutions[j], mean, spread, minimum, maximum );

		if ( spread > tolerance || b3AbsFloat( mean - restitutions[j] ) > tolerance )
		{
			failed = 1;
		}
	}

	return failed;
}

// By default the restitution stage sweeps only the contacts that carry restitution, so the ball
// pushes the column down and the ground under it gets no say until the next step: e = 0.9 gives
// about 0.52 on one support. With propagation enabled the stage sweeps every contact, the ground
// contact supplies the reaction within the stage and e = 0.9 gives 0.85 on one support and 0.72 on
// three at the pinned four iterations, decaying with depth because the column needs an iteration per
// level. Propagation costs a normal pass over every contact per iteration, hence the option. Both
// modes are gated: never above the free coefficient, which would be energy from nowhere, and never
// collapsed.
static int SupportedTest( void )
{
	static const float restitutions[] = { 0.5f, 0.9f };

	int failed = 0;

	for ( int propagate = 0; propagate <= 1; ++propagate )
	{
		float floor = propagate ? 0.75f : 0.5f;

		for ( int j = 0; j < ARRAY_COUNT( restitutions ); ++j )
		{
			for ( int n = 0; n <= 3; ++n )
			{
				float measured = MeasureSupportedBounce( restitutions[j], n, propagate == 1 );
				printf( "    supported e %.2f supports %d propagation %d -> %.4f\n", restitutions[j], n, propagate, measured );

				if ( measured > restitutions[j] + 0.01f || measured < floor * restitutions[j] )
				{
					failed = 1;
				}
			}
		}
	}

	return failed;
}

// A symmetric four point landing. The stage solves the points in sequence, so a single sweep leaves
// the box spinning: the first impulse tilts it and the next point sees a larger closing speed. Four
// stage iterations converge the coupling and leave a small residual. The tolerance admits that
// residual and rejects the single sweep behavior.
static int FlatLandingTest( void )
{
	static const float restitutions[] = { 0.5f, 0.9f };
	static const int subStepCounts[] = { 4, 8 };
	const float speedTolerance = 0.01f;
	const float spinTolerance = 0.03f;

	int failed = 0;

	for ( int j = 0; j < ARRAY_COUNT( restitutions ); ++j )
	{
		for ( int k = 0; k < ARRAY_COUNT( subStepCounts ); ++k )
		{
			float spin = 0.0f;
			float measured = MeasureFlatBounce( restitutions[j], subStepCounts[k], &spin );
			printf( "    flat e %.2f substeps %d -> %.4f spin %.4f\n", restitutions[j], subStepCounts[k], measured, spin );

			// Only the shipping sub step count is a gate. The wider count is reported so a
			// convergence problem can be told apart from a formulation problem.
			if ( subStepCounts[k] != SUB_STEP_COUNT )
			{
				continue;
			}

			if ( b3AbsFloat( measured - restitutions[j] ) > speedTolerance || spin > spinTolerance )
			{
				failed = 1;
			}
		}
	}

	return failed;
}

// A flat box carrying spin about a horizontal axis. All four corners stay in contact and the normal
// constraints are linear in the body velocity, so perfect restitution reverses linear and angular
// velocity. Four stage iterations bring both within a few thousandths.
static int SpinTest( void )
{
	static const float spins[] = { 0.0f, 0.5f, 1.0f, 2.0f };

	int failed = 0;

	for ( int j = 0; j < ARRAY_COUNT( spins ); ++j )
	{
		b3WorldId worldId = MakeWorldIterations( 0.0f, RESTITUTION_ITERATIONS );
		MakeGround( worldId, 0.0f );

		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.type = b3_dynamicBody;
		bodyDef.position = (b3Pos){ 0.0f, 0.25f + 0.5f * IMPACT_SPEED * TIME_STEP, 0.0f };
		bodyDef.linearVelocity = (b3Vec3){ 0.0f, -IMPACT_SPEED, 0.0f };
		bodyDef.angularVelocity = (b3Vec3){ 0.0f, 0.0f, spins[j] };
		b3BodyId boxId = b3CreateBody( worldId, &bodyDef );

		b3ShapeDef shapeDef = b3DefaultShapeDef();
		shapeDef.density = 1.0f;
		shapeDef.baseMaterial.friction = 0.0f;
		shapeDef.baseMaterial.restitution = 1.0f;
		b3BoxHull box = b3MakeBoxHull( 1.0f, 0.25f, 1.0f );
		b3CreateHullShape( boxId, &shapeDef, &box.base );

		for ( int i = 0; i < 60; ++i )
		{
			b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );
		}

		float speed = b3Body_GetLinearVelocity( boxId ).y;
		float spin = b3Body_GetAngularVelocity( boxId ).z;
		b3DestroyWorld( worldId );

		printf( "    spin in %+.2f -> vy %+.4f (want %+.4f)  wz %+.4f (want %+.4f)\n", spins[j], speed, IMPACT_SPEED, spin,
				-spins[j] );

		if ( b3AbsFloat( speed - IMPACT_SPEED ) > 0.05f || b3AbsFloat( spin + spins[j] ) > 0.05f )
		{
			failed = 1;
		}
	}

	return failed;
}

// Perfectly elastic ball under gravity. Only heights where continuous collision engages are used.
// Continuous collision lands the ball on the surface, so the bounce is armed from the true impact
// speed and the apex holds. Slower drops resolve the impact inside the overlap and the penetration
// recovery adds height, by design. The 10 m case is the long horizon read.
static int DropTest( void )
{
	static const float heights[] = { 40.0f, 20.0f, 10.0f };

	int failed = 0;

	for ( int j = 0; j < ARRAY_COUNT( heights ); ++j )
	{
		float apexes[6] = { 0 };
		int apexCount = MeasureDrop( heights[j], apexes, ARRAY_COUNT( apexes ) );

		printf( "    drop %5.1f ->", heights[j] );
		for ( int i = 0; i < apexCount; ++i )
		{
			printf( " %8.3f", apexes[i] );
		}
		printf( "\n" );

		if ( apexCount < ARRAY_COUNT( apexes ) )
		{
			failed = 1;
			continue;
		}

		float highest = apexes[0];
		for ( int i = 1; i < apexCount; ++i )
		{
			highest = b3MaxFloat( highest, apexes[i] );
		}

		// A later apex above the first, or a first apex above the drop, is energy from nowhere
		if ( highest > 1.001f * apexes[0] || apexes[0] > 1.001f * heights[j] || apexes[apexCount - 1] < 0.8f * apexes[0] )
		{
			failed = 1;
		}
	}

	return failed;
}

// A cube dropped flat with an aggressive continuous safety factor so it lands square on the surface.
// Perfectly elastic and frictionless, so it should come back to the drop height with no rotation. A
// flat landing solves four coplanar points in sequence and one sweep over-delivers: the first impulse
// tilts the cube, the next point sees a larger closing speed and the sum overshoots the rigid body
// answer, leaving spin that tilts the cube for the next landing. Four stage iterations converge the
// coupling. The bounds below reject the single sweep behavior and any apex above the drop.
static int SingleBoxTest( void )
{
	b3WorldId worldId = MakeWorldIterations( -10.0f, RESTITUTION_ITERATIONS );
	MakeGround( worldId, 0.0f );

	b3ShapeDef shapeDef = b3DefaultShapeDef();
	shapeDef.density = 1.0f;
	shapeDef.baseMaterial.friction = 0.0f;
	shapeDef.baseMaterial.restitution = 1.0f;
	b3BoxHull box = b3MakeCubeHull( 0.5f );

	const float dropHeight = 10.0f;

	b3BodyDef bodyDef = b3DefaultBodyDef();
	bodyDef.type = b3_dynamicBody;
	bodyDef.position = (b3Pos){ 0.0f, dropHeight, 0.0f };
	bodyDef.safetyFactor = 0.01f;
	b3BodyId boxId = b3CreateBody( worldId, &bodyDef );
	b3CreateHullShape( boxId, &shapeDef, &box.base );

	float firstSpin = 0.0f;
	float apexes[4] = { 0 };
	float spins[4] = { 0 };
	int apexCount = 0;
	float previousSpeed = 0.0f;

	// A nearly elastic bounce from 10 m takes about 165 steps, so budget for four of them
	for ( int i = 0; i < 1200 && apexCount < ARRAY_COUNT( apexes ); ++i )
	{
		b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );

		float speed = b3Body_GetLinearVelocity( boxId ).y;

		if ( apexCount == 0 && previousSpeed <= 0.0f && speed > 0.0f )
		{
			firstSpin = b3Length( b3Body_GetAngularVelocity( boxId ) );
		}

		if ( previousSpeed > 0.0f && speed <= 0.0f )
		{
			apexes[apexCount] = (float)b3Body_GetPosition( boxId ).y;
			spins[apexCount] = b3Length( b3Body_GetAngularVelocity( boxId ) );
			apexCount += 1;
		}
		previousSpeed = speed;
	}

	b3DestroyWorld( worldId );

	printf( "    single box first bounce spin %.4f apexes", firstSpin );
	for ( int i = 0; i < apexCount; ++i )
	{
		printf( " %7.3f (spin %5.2f)", apexes[i], spins[i] );
	}
	printf( "\n" );

	ENSURE( apexCount == ARRAY_COUNT( apexes ) );

	int failed = 0;

	if ( firstSpin > 0.01f )
	{
		failed = 1;
	}

	for ( int i = 0; i < apexCount; ++i )
	{
		if ( apexes[i] < 0.95f * dropHeight || apexes[i] > 1.001f * dropHeight )
		{
			failed = 1;
		}
	}

	return failed;
}

static int ThresholdTest( void )
{
	b3WorldDef worldDef = b3DefaultWorldDef();
	float threshold = worldDef.restitutionThreshold;

	static const float scales[] = { 0.5f, 0.9f, 1.5f, 4.0f };

	int failed = 0;

	for ( int j = 0; j < ARRAY_COUNT( scales ); ++j )
	{
		float speed = scales[j] * threshold;

		b3WorldId worldId = MakeWorld( 0.0f );
		MakeGround( worldId, 0.0f );
		b3BodyId ballId = MakeBall( worldId, 0.0f, 0.5f + 0.5f * speed * TIME_STEP, -speed, 1.0f );

		for ( int i = 0; i < 60; ++i )
		{
			b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );
		}

		float ratio = b3Body_GetLinearVelocity( ballId ).y / speed;
		b3DestroyWorld( worldId );

		printf( "    threshold %.2fx -> %.4f\n", scales[j], ratio );

		if ( scales[j] < 1.0f && ratio > 0.05f )
		{
			failed = 1;
		}

		if ( scales[j] > 1.0f && ratio < 0.9f )
		{
			failed = 1;
		}
	}

	return failed;
}

// High restitution must not wake a settled stack back up
static int RestingTest( void )
{
	b3WorldId worldId = MakeWorld( -10.0f );
	MakeGround( worldId, 0.9f );

	const int boxCount = 10;
	b3BodyId boxIds[10];

	b3ShapeDef shapeDef = b3DefaultShapeDef();
	shapeDef.density = 1.0f;
	shapeDef.baseMaterial.friction = 0.6f;
	shapeDef.baseMaterial.restitution = 0.9f;
	b3BoxHull box = b3MakeCubeHull( 0.5f );

	for ( int i = 0; i < boxCount; ++i )
	{
		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.type = b3_dynamicBody;
		bodyDef.position = (b3Pos){ 0.0f, 0.5f + 1.0f * i, 0.0f };
		boxIds[i] = b3CreateBody( worldId, &bodyDef );
		b3CreateHullShape( boxIds[i], &shapeDef, &box.base );
	}

	for ( int i = 0; i < 240; ++i )
	{
		b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );
	}

	float settled = (float)b3Body_GetPosition( boxIds[boxCount - 1] ).y;
	float drift = 0.0f;
	float peakSpeed = 0.0f;

	for ( int i = 0; i < 300; ++i )
	{
		b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );

		float y = (float)b3Body_GetPosition( boxIds[boxCount - 1] ).y;
		drift = b3MaxFloat( drift, b3AbsFloat( y - settled ) );

		for ( int j = 0; j < boxCount; ++j )
		{
			peakSpeed = b3MaxFloat( peakSpeed, b3Length( b3Body_GetLinearVelocity( boxIds[j] ) ) );
		}
	}

	b3DestroyWorld( worldId );

	printf( "    resting drift %.5f peak speed %.5f\n", drift, peakSpeed );

	ENSURE( drift < 0.01f );
	ENSURE( peakSpeed < 0.05f );
	return 0;
}

static uint64_t RunWorkerScene( int workerCount )
{
	b3WorldDef worldDef = b3DefaultWorldDef();
	worldDef.gravity = (b3Vec3){ 0.0f, -10.0f, 0.0f };
	worldDef.enableSleep = false;
	worldDef.workerCount = workerCount;
	b3WorldId worldId = b3CreateWorld( &worldDef );

	MakeGround( worldId, 0.6f );

	for ( int i = 0; i < 20; ++i )
	{
		MakeBall( worldId, -10.0f + 1.05f * i, 3.0f + 0.13f * i, 0.0f, 0.6f );
	}

	for ( int i = 0; i < 200; ++i )
	{
		b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );
	}

	uint64_t hash = b3HashWorldState( b3GetWorldFromId( worldId ) );
	b3DestroyWorld( worldId );
	return hash;
}

// The manifold point approach speed is published only for contacts that opted into hit events. It
// is not a stale value otherwise, it is zero, so a reader can tell "not measured" from "measured
// zero" by whether the shape enables the events. Restitution no longer reads it at all, so this is
// the only thing keeping the field alive.
static float MeasureFirstTouchNormalVelocity( bool enableHitEvents )
{
	b3WorldId worldId = MakeWorld( 0.0f );
	MakeGround( worldId, 0.0f );

	b3BodyDef bodyDef = b3DefaultBodyDef();
	bodyDef.type = b3_dynamicBody;
	bodyDef.position = (b3Pos){ 0.0f, 0.6f, 0.0f };
	b3BodyId ballId = b3CreateBody( worldId, &bodyDef );

	b3ShapeDef shapeDef = b3DefaultShapeDef();
	shapeDef.baseMaterial.friction = 0.0f;
	shapeDef.baseMaterial.restitution = 0.0f;
	shapeDef.enableHitEvents = enableHitEvents;
	b3Sphere sphere = { { 0.0f, 0.0f, 0.0f }, 0.5f };
	b3CreateSphereShape( ballId, &shapeDef, &sphere );

	float normalVelocity = FLT_MAX;

	// Hold the closing speed so the sampled value does not depend on which step the pair is created
	for ( int i = 0; i < 20; ++i )
	{
		b3Body_SetLinearVelocity( ballId, (b3Vec3){ 0.0f, -IMPACT_SPEED, 0.0f } );
		b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );

		b3ContactData contactData;
		if ( b3Body_GetContactData( ballId, &contactData, 1 ) == 1 && contactData.manifoldCount > 0 &&
			 contactData.manifolds[0].pointCount > 0 )
		{
			normalVelocity = contactData.manifolds[0].points[0].normalVelocity;
			break;
		}
	}

	b3DestroyWorld( worldId );
	return normalVelocity;
}

static int NormalVelocityTest( void )
{
	float quiet = MeasureFirstTouchNormalVelocity( false );
	float published = MeasureFirstTouchNormalVelocity( true );

	printf( "    normal velocity hit events off %.4f on %.4f (closing at %.4f)\n", quiet, published, -IMPACT_SPEED );

	int failed = 0;

	if ( quiet != 0.0f )
	{
		failed = 1;
	}

	if ( published > -0.8f * IMPACT_SPEED )
	{
		failed = 1;
	}

	return failed;
}

// Mechanical energy of a body as symplectic Euler conserves it. The integrator updates velocity
// before position, so the quantity that is exactly constant in free flight is not kinetic plus
// potential but that plus half a sub-step of the gravity power, m * dot(v, g) * h / 2. Plain
// kinetic plus potential sampled at step boundaries jumps by about g * v * h at every bounce and
// drifts down by g^2 h^2 / 2 each sub-step, which would hide a real gain or fake one. With this
// measure a contact that never does positive work leaves the energy flat to round-off.
static float MeasureEnergy( b3BodyId bodyId, b3WorldId worldId )
{
	b3MassData massData = b3Body_GetMassData( bodyId );
	b3Vec3 v = b3Body_GetLinearVelocity( bodyId );
	b3Vec3 gravity = b3MulSV( b3Body_GetGravityScale( bodyId ), b3World_GetGravity( worldId ) );
	float h = TIME_STEP / SUB_STEP_COUNT;

	// The inertia tensor is in the body frame, so bring the angular velocity back to it
	b3Vec3 wLocal = b3InvRotateVector( b3Body_GetRotation( bodyId ), b3Body_GetAngularVelocity( bodyId ) );

	float kinetic = 0.5f * massData.mass * b3Dot( v, v ) + 0.5f * b3Dot( wLocal, b3MulMV( massData.inertia, wLocal ) );
	float potential = -massData.mass * b3Dot( gravity, b3ToVec3( b3Body_GetWorldCenter( bodyId ) ) );
	float phase = 0.5f * h * massData.mass * b3Dot( v, gravity );

	return kinetic + potential + phase;
}

typedef struct OvershootResult
{
	float firstApex;
	float firstEnergyRatio;
	float peakEnergyRatio;
	float speedRatio;
	int bounceCount;
} OvershootResult;

// Mirrors the Restitution Overshoot sample in samples/sample_issues.cpp: a unit cube dropped flat on
// a floor narrower than itself, perfectly elastic, so the four contact points sit inboard of the box
// corners. A perfectly elastic bounce cannot come back higher than it was dropped from and cannot
// gain energy.
static OvershootResult MeasureOvershoot( bool continuous )
{
	b3WorldId worldId = MakeWorldIterations( -10.0f, RESTITUTION_ITERATIONS );

	b3BodyDef floorDef = b3DefaultBodyDef();
	floorDef.position = (b3Pos){ 0.0f, -0.25f, 0.0f };
	b3BodyId floorId = b3CreateBody( worldId, &floorDef );

	b3ShapeDef floorShape = b3DefaultShapeDef();
	b3BoxHull floor = b3MakeBoxHull( 0.375f, 0.25f, 0.375f );
	b3CreateHullShape( floorId, &floorShape, &floor.base );

	const float dropHeight = 10.0f;

	b3BodyDef boxDef = b3DefaultBodyDef();
	boxDef.type = b3_dynamicBody;
	boxDef.position = (b3Pos){ 0.0f, dropHeight, 0.0f };
	if ( continuous )
	{
		boxDef.safetyFactor = 0.1f;
	}
	b3BodyId boxId = b3CreateBody( worldId, &boxDef );

	b3ShapeDef boxShape = b3DefaultShapeDef();
	boxShape.baseMaterial.restitution = 1.0f;
	b3BoxHull box = b3MakeCubeHull( 0.5f );
	b3CreateHullShape( boxId, &boxShape, &box.base );

	OvershootResult result = { 0 };

	float startEnergy = MeasureEnergy( boxId, worldId );
	float impactSpeed = 0.0f;
	float reboundSpeed = 0.0f;
	float bounceHeight = 0.0f;
	float previousSpeed = 0.0f;

	for ( int i = 0; i < 600 && result.bounceCount < 2; ++i )
	{
		float before = b3Body_GetLinearVelocity( boxId ).y;
		float heightBefore = (float)b3Body_GetPosition( boxId ).y;
		b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );
		float speed = b3Body_GetLinearVelocity( boxId ).y;

		if ( reboundSpeed == 0.0f && before < 0.0f && speed > 0.0f )
		{
			impactSpeed = -before;
			reboundSpeed = speed;
			bounceHeight = heightBefore;
		}

		if ( reboundSpeed == 0.0f )
		{
			continue;
		}

		// Every step, not just at the apexes, because that is what the sample checks and the impact
		// step itself is where any gain appears
		float ratio = MeasureEnergy( boxId, worldId ) / startEnergy;
		if ( ratio > result.peakEnergyRatio )
		{
			result.peakEnergyRatio = ratio;
		}

		if ( previousSpeed > 0.0f && speed <= 0.0f )
		{
			if ( result.bounceCount == 0 )
			{
				result.firstApex = (float)b3Body_GetPosition( boxId ).y;
				result.firstEnergyRatio = ratio;
			}

			result.bounceCount += 1;
		}

		previousSpeed = speed;
	}

	b3DestroyWorld( worldId );

	result.speedRatio = reboundSpeed / impactSpeed;

	printf( "    overshoot continuous %d apex %.4f of %.4f at y %.4f, speed ratio %.4f, energy %.4f then %.4f\n",
			continuous ? 1 : 0, result.firstApex, dropHeight, bounceHeight, result.speedRatio, result.firstEnergyRatio,
			result.peakEnergyRatio );

	return result;
}

// Two runs, because two unrelated effects were tangled together here.
//
// The impulse must never return more speed than it received. That is the restitution invariant and it
// is checked in both runs; the unconverged four point solve failed it by 7.9 percent.
//
// Everything else depends on whether continuous collision engages. Without it the cube moves 0.23 m
// in the step before contact, just under the 0.25 m trigger, so the first manifold appears with the
// cube already 0.10 m deep. It bounces from down there and climbs back through that depth for free,
// which is worth about a tenth of a metre of apex and one percent of energy, and none of it is
// restitution. With continuous collision the cube lands on the surface and both the apex and the
// energy come in under where they started. The safety factor here matches the one the sample sets,
// which is the supported answer for a body whose elastic accuracy matters.
//
// The discrete run is only gated on its first bounce. Later bounces there are a genuine blow-up, not
// a tolerance question: the free height makes the cube tilt, the next landing is a deep corner impact
// at 14 m/s, and energy reaches 159 percent with the cube spinning at 26 rad/s. Lowering the safety
// factor is the fix and the sample does that; the discrete run is kept to pin what happens when it is
// left alone, and because its speed ratio is what caught the real bug. Details in
// .claude/same_step_restitution.md.
static int OvershootTest( void )
{
	const float dropHeight = 10.0f;

	OvershootResult discrete = MeasureOvershoot( false );
	OvershootResult continuous = MeasureOvershoot( true );

	// Perfectly elastic returns exactly the speed it received, so any excess is round-off. The
	// overflow and colored solvers round differently and either can land an ulp over one.
	const float speedTolerance = 1.0e-5f;

	int failed = 0;

	if ( discrete.speedRatio > 1.0f + speedTolerance || continuous.speedRatio > 1.0f + speedTolerance )
	{
		failed = 1;
	}

	if ( continuous.firstApex > dropHeight || continuous.peakEnergyRatio > 1.001f )
	{
		failed = 1;
	}

	if ( discrete.firstApex > dropHeight + 0.15f || discrete.firstEnergyRatio > 1.02f )
	{
		failed = 1;
	}

	// The continuous landing leaves the cube sliding sideways a few tenths of a metre per second, from
	// friction during the sub-steps, and a floor narrower than the cube does not catch it on the way
	// back down. That is sub-step friction, not restitution, so only the first bounce is required.
	if ( discrete.bounceCount < 2 || continuous.bounceCount < 1 )
	{
		failed = 1;
	}

	return failed;
}

typedef struct ImpulseResult
{
	float worstError;
	float approachSpeed;
	float firstSeparation;
	float bounceImpulse;
	int contactSteps;
	int toiSteps;
	int toiImpulseSteps;
} ImpulseResult;

// Ball dropped under gravity with the contact impulse read back every step. Nothing else touches the
// ball, so once gravity is taken out the change in momentum over a step is the impulse the contact
// applied, and that is what the total normal impulse must report. A time of impact step is left out
// of the balance: no contact was solved on it, and the sweep hands back the gravity of the time it
// cut short.
static ImpulseResult MeasureDropImpulse( float restitution, float dropHeight )
{
	b3WorldId worldId = MakeWorld( -10.0f );
	MakeGround( worldId, 0.0f );

	b3BodyId ballId = MakeBall( worldId, 0.0f, 0.5f + dropHeight, 0.0f, restitution );
	b3World* world = b3GetWorldFromId( worldId );

	float mass = b3Body_GetMass( ballId );
	float gravityY = b3World_GetGravity( worldId ).y;

	ImpulseResult result = { 0 };
	bool touched = false;
	bool bouncing = false;

	// Enough for the longest fall and the bounce that follows it
	for ( int i = 0; i < 240; ++i )
	{
		float speedBefore = b3Body_GetLinearVelocity( ballId ).y;
		b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );
		float speedAfter = b3Body_GetLinearVelocity( ballId ).y;

		float measured = 0.0f;
		float separation = 0.0f;
		b3ContactData contactData[4];
		int contactCount = b3Body_GetContactData( ballId, contactData, ARRAY_COUNT( contactData ) );
		for ( int c = 0; c < contactCount; ++c )
		{
			for ( int m = 0; m < contactData[c].manifoldCount; ++m )
			{
				const b3Manifold* manifold = contactData[c].manifolds + m;
				for ( int p = 0; p < manifold->pointCount; ++p )
				{
					measured += manifold->points[p].totalNormalImpulse;
					separation = manifold->points[p].separation;
				}
			}
		}

		// Transient body flags are cleared and rewritten every step
		b3Body* ball = b3GetBodyFullId( world, ballId );
		b3BodySim* ballSim = b3GetBodySim( world, ball );
		if ( ballSim->flags & b3_hadTimeOfImpact )
		{
			result.toiSteps += 1;
			if ( measured != 0.0f )
			{
				result.toiImpulseSteps += 1;
			}
			continue;
		}

		float expected = mass * ( speedAfter - speedBefore ) - mass * gravityY * TIME_STEP;
		result.worstError = b3MaxFloat( result.worstError, b3AbsFloat( measured - expected ) );

		if ( contactCount > 0 )
		{
			if ( touched == false )
			{
				touched = true;
				bouncing = true;
				result.approachSpeed = -speedBefore;
				result.firstSeparation = separation;
			}

			if ( bouncing )
			{
				result.bounceImpulse += measured;
				result.contactSteps += 1;
			}
		}
		else
		{
			bouncing = false;
		}
	}

	b3DestroyWorld( worldId );
	return result;
}

// Heights on both sides of the continuous collision threshold, so the impulse is checked for a ball
// that lands inside the overlap and for one the sweep sets down on the surface. The threshold is
// derived from the body so the split survives a change to the default safety factor.
//
// The step balance is the real gate. The bounce total is bracketed as well so the restitution sweep
// means something: the contact has to reverse the approach at the coefficient and may carry the
// weight for at most as long as it lasted. The stage runs after the sub-steps, so the reversal
// lands a step late and the ball can come in up to a step of gravity under it.
static int ImpulseTest( void )
{
	static const float restitutions[] = { 0.0f, 0.25f, 0.5f, 0.75f, 1.0f };
	static const float heights[] = { 1.0f, 5.0f, 20.0f, 45.0f };

	float mass;
	float fastSpeed;
	{
		b3WorldId worldId = MakeWorld( -10.0f );
		b3BodyId ballId = MakeBall( worldId, 0.0f, 0.5f, 0.0f, 0.0f );
		mass = b3Body_GetMass( ballId );
		fastSpeed = b3Body_GetSafetyFactor( ballId ) * b3Body_GetMinExtent( ballId ) / TIME_STEP;
		b3DestroyWorld( worldId );
	}

	const float weightImpulse = mass * 10.0f * TIME_STEP;

	int failed = 0;

	for ( int j = 0; j < ARRAY_COUNT( heights ); ++j )
	{
		float impactSpeed = sqrtf( 20.0f * heights[j] );
		bool expectToi = impactSpeed > fastSpeed;

		// Float noise in the solver velocities scales with the impact speed, and the ball is heavy
		float tolerance = 1e-5f * mass * ( 10.0f + impactSpeed );

		for ( int k = 0; k < ARRAY_COUNT( restitutions ); ++k )
		{
			ImpulseResult result = MeasureDropImpulse( restitutions[k], heights[j] );

			float reversal = ( 1.0f + restitutions[k] ) * mass * result.approachSpeed;
			float lower = reversal - weightImpulse;
			float upper = reversal + weightImpulse * result.contactSteps;

			printf( "    impulse drop %4.1f e %.2f toi %d at %+.4f -> worst step error %.1e, bounce %.1f in [%.1f, %.1f] over %d "
					"steps\n",
					heights[j], restitutions[k], result.toiSteps, result.firstSeparation, result.worstError, result.bounceImpulse,
					lower, upper, result.contactSteps );

			if ( result.worstError > tolerance )
			{
				failed = 1;
			}

			if ( result.contactSteps == 0 || result.toiImpulseSteps > 0 )
			{
				failed = 1;
			}

			float slack = result.contactSteps * tolerance;
			if ( result.bounceImpulse < lower - slack || result.bounceImpulse > upper + slack )
			{
				failed = 1;
			}

			if ( ( result.toiSteps > 0 ) != expectToi )
			{
				printf( "    continuous collision %s at %.1f m/s (threshold %.1f m/s)\n", expectToi ? "expected" : "unexpected",
						impactSpeed, fastSpeed );
				failed = 1;
			}
		}
	}

	return failed;
}

typedef struct EnergyScene
{
	const char* name;
	float safetyFactor;
	float friction;
	float angle;
	float spin;
	float height;
	float velocityY;
	float halfWidth;
	float halfHeight;
	bool bullet;
	bool stack;
	int stepCount;
} EnergyScene;

// Peak energy over the run relative to the start, for every dynamic body in the scene. Perfectly
// elastic and the energy may still only go down: friction and the soft contact position correction
// dissipate, and a bounce may return at most what the contact absorbed.
static float MeasurePeakEnergy( const EnergyScene* scene )
{
	b3WorldId worldId = MakeWorld( -10.0f );

	b3BodyDef groundDef = b3DefaultBodyDef();
	groundDef.position = (b3Pos){ 0.0f, -1.0f, 0.0f };
	b3BodyId groundId = b3CreateBody( worldId, &groundDef );
	b3ShapeDef groundShape = b3DefaultShapeDef();
	groundShape.baseMaterial.friction = scene->friction;
	b3BoxHull ground = b3MakeBoxHull( 40.0f, 1.0f, 40.0f );
	b3CreateHullShape( groundId, &groundShape, &ground.base );

	b3ShapeDef shapeDef = b3DefaultShapeDef();
	shapeDef.density = 1.0f;
	shapeDef.baseMaterial.friction = scene->friction;
	shapeDef.baseMaterial.restitution = 1.0f;
	b3BoxHull box = b3MakeBoxHull( scene->halfWidth, scene->halfHeight, scene->halfWidth );

	b3BodyId bodyIds[4];
	int bodyCount = 0;

	if ( scene->stack )
	{
		// Resting box under the dropped one, like the TwoBoxRestitution sample
		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.type = b3_dynamicBody;
		bodyDef.position = (b3Pos){ 0.0f, scene->halfHeight, 0.0f };
		bodyDef.safetyFactor = scene->safetyFactor;
		bodyIds[bodyCount] = b3CreateBody( worldId, &bodyDef );
		b3CreateHullShape( bodyIds[bodyCount], &shapeDef, &box.base );
		bodyCount += 1;
	}

	{
		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.type = b3_dynamicBody;
		bodyDef.position = (b3Pos){ 0.0f, scene->height, 0.0f };
		bodyDef.rotation = b3MakeQuatFromAxisAngle( b3Vec3_axisZ, scene->angle );
		bodyDef.angularVelocity = (b3Vec3){ 0.0f, 0.0f, scene->spin };
		bodyDef.linearVelocity = (b3Vec3){ 0.0f, scene->velocityY, 0.0f };
		bodyDef.safetyFactor = scene->safetyFactor;
		bodyDef.isBullet = scene->bullet;
		bodyIds[bodyCount] = b3CreateBody( worldId, &bodyDef );
		b3CreateHullShape( bodyIds[bodyCount], &shapeDef, &box.base );
		bodyCount += 1;
	}

	float start = 0.0f;
	for ( int k = 0; k < bodyCount; ++k )
	{
		start += MeasureEnergy( bodyIds[k], worldId );
	}

	float peak = start;
	int peakStep = -1;

	for ( int i = 0; i < scene->stepCount; ++i )
	{
		b3World_Step( worldId, TIME_STEP, SUB_STEP_COUNT );

		float energy = 0.0f;
		for ( int k = 0; k < bodyCount; ++k )
		{
			energy += MeasureEnergy( bodyIds[k], worldId );
		}

		if ( energy > peak )
		{
			peak = energy;
			peakStep = i;
		}
	}

	b3DestroyWorld( worldId );

	float ratio = peak / start;
	printf( "    energy %-24s peak %.5f at step %d\n", scene->name, ratio, peakStep );
	return ratio;
}

// Perfectly elastic material with friction, dropped every way that used to gain energy: a spinning
// edge landing, tumbling, a flat landing with spin, a box falling on a resting box, and a tall box
// landing flat on its narrow end. Energy must never rise above the start. This is the load bearing
// property of restitution. Accuracy of the coefficient and freedom from spin are secondary.
//
// The tall boxes guard the stage iteration count. Their contact points sit close together while the
// inertia is long, so the off diagonal of the multi point normal mass is large and one sweep
// overshoots.
static int EnergyTest( void )
{
	static const EnergyScene scenes[] = {
		{ "spinning edge", 0.01f, 0.6f, -1.43f, 7.9f, 0.7f, -1.9f, 0.5f, 0.5f, false, false, 300 },
		{ "spinning edge fast", 0.01f, 0.6f, -0.8f, 12.0f, 3.0f, -8.0f, 0.5f, 0.5f, false, false, 300 },
		{ "tumble", 0.01f, 0.6f, -0.3f, 3.0f, 8.0f, 0.0f, 0.5f, 0.5f, false, false, 600 },
		{ "tumble discrete", 0.5f, 0.6f, -0.3f, 3.0f, 8.0f, 0.0f, 0.5f, 0.5f, false, false, 600 },
		{ "flat with spin", 0.01f, 0.6f, 0.0f, 2.0f, 2.0f, -5.0f, 0.5f, 0.5f, false, false, 300 },
		{ "flat frictionless", 0.01f, 0.0f, 0.0f, 0.0f, 10.0f, 0.0f, 0.5f, 0.5f, false, false, 1200 },
		{ "edge", 0.01f, 0.6f, -0.2f, 0.0f, 5.0f, 0.0f, 0.5f, 0.5f, false, false, 600 },
		{ "two box", 0.02f, 0.6f, 0.0f, 0.0f, 4.0f, 0.0f, 0.5f, 0.5f, true, true, 1500 },
		{ "two box discrete", 0.5f, 0.6f, 0.0f, 0.0f, 4.0f, 0.0f, 0.5f, 0.5f, false, true, 1500 },
		{ "tall flat frictionless", 0.01f, 0.0f, 0.0f, 0.0f, 10.0f, 0.0f, 0.5f, 1.0f, false, false, 1200 },
		{ "tall flat friction", 0.01f, 0.6f, 0.0f, 0.0f, 10.0f, 0.0f, 0.5f, 1.0f, false, false, 1200 },
		{ "narrow flat frictionless", 0.01f, 0.0f, 0.0f, 0.0f, 10.0f, 0.0f, 0.25f, 1.0f, false, false, 1200 },
		{ "narrow flat friction", 0.01f, 0.6f, 0.0f, 0.0f, 10.0f, 0.0f, 0.25f, 1.0f, false, false, 1200 },
	};

	// The soft contact position correction lifts a body that lands inside the ground, which is
	// potential energy from nowhere at any restitution. Continuous collision keeps landings on the
	// surface, so the tolerance only has to cover the stage. A four point flat landing does not
	// converge at the default two stage iterations the way the two point landing does in 2D: the cube
	// comes back with 0.2% extra. The in-relax scheme this replaced gained 2.5% to 29% on these scenes,
	// so the tolerance still separates the two.
	const float tolerance = 5.0e-3f;
	const float discreteTolerance = 2.0e-2f;

	int failed = 0;

	for ( int i = 0; i < ARRAY_COUNT( scenes ); ++i )
	{
		float ratio = MeasurePeakEnergy( scenes + i );
		float limit = scenes[i].safetyFactor < 0.1f ? tolerance : discreteTolerance;
		if ( ratio > 1.0f + limit )
		{
			failed = 1;
		}
	}

	return failed;
}

// The sampled approach speed and the Poisson accumulator are per manifold point state, so they must
// survive the split across workers
static int WorkerParityTest( void )
{
	uint64_t hash1 = RunWorkerScene( 1 );
	uint64_t hash2 = RunWorkerScene( 2 );
	uint64_t hash4 = RunWorkerScene( 4 );

	printf( "    worker hashes 0x%016llx 0x%016llx 0x%016llx\n", (unsigned long long)hash1, (unsigned long long)hash2,
			(unsigned long long)hash4 );

	ENSURE( hash1 == hash2 );
	ENSURE( hash1 == hash4 );
	return 0;
}

int RestitutionTest( void )
{
	int failureCount = 0;

	RUN_MEASUREMENT( HeadOnTest );
	RUN_MEASUREMENT( PhaseTest );
	RUN_MEASUREMENT( SupportedTest );
	RUN_MEASUREMENT( FlatLandingTest );
	RUN_MEASUREMENT( SpinTest );
	RUN_MEASUREMENT( DropTest );
	RUN_MEASUREMENT( SingleBoxTest );
	RUN_MEASUREMENT( ThresholdTest );
	RUN_MEASUREMENT( RestingTest );
	RUN_MEASUREMENT( NormalVelocityTest );
	RUN_MEASUREMENT( OvershootTest );
	RUN_MEASUREMENT( EnergyTest );
	RUN_MEASUREMENT( ImpulseTest );
	RUN_MEASUREMENT( WorkerParityTest );

	return failureCount > 0 ? 1 : 0;
}

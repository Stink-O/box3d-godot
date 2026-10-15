// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

#include "joint.h"
#include "test_macros.h"

#include "box3d/box3d.h"
#include "box3d/math_functions.h"

#include <float.h>
#include <math.h>

// One sub-test per joint type. Each creates the joint, exercises the shared
// b3Joint_* API plus every type-specific accessor, then steps to make sure the
// joint solves without tripping a validation assert.

typedef struct JointFixture
{
	b3WorldId worldId;
	b3BodyId groundId;
	b3BodyId bodyId;
} JointFixture;

// Static ground plus a dynamic box, anchored so a point-coincident joint starts
// satisfied. Gravity is off so the body stays put across the handful of steps
// each sub-test takes.
static JointFixture CreateJointFixture( void )
{
	b3WorldDef worldDef = b3DefaultWorldDef();
	worldDef.gravity = b3Vec3_zero;

	JointFixture f;
	f.worldId = b3CreateWorld( &worldDef );

	b3BodyDef groundDef = b3DefaultBodyDef();
	f.groundId = b3CreateBody( f.worldId, &groundDef );

	b3BodyDef bodyDef = b3DefaultBodyDef();
	bodyDef.type = b3_dynamicBody;
	bodyDef.position = (b3Pos){ 0.0f, 4.0f, 0.0f };
	f.bodyId = b3CreateBody( f.worldId, &bodyDef );

	b3ShapeDef shapeDef = b3DefaultShapeDef();
	shapeDef.density = 1.0f;
	b3BoxHull box = b3MakeCubeHull( 0.5f );
	b3CreateHullShape( f.bodyId, &shapeDef, &box.base );

	return f;
}

// Place the joint anchor at the dynamic body so both local frames map to the
// same world point.
static void SetCommonFrames( b3JointDef* base, const JointFixture* f )
{
	base->bodyIdA = f->groundId;
	base->bodyIdB = f->bodyId;
	base->localFrameA.p = (b3Vec3){ 0.0f, 4.0f, 0.0f };
	base->localFrameB.p = (b3Vec3){ 0.0f, 0.0f, 0.0f };
}

// Step a few times, destroy the joint, then the world. Destroying the joint
// explicitly also covers b3DestroyJoint and stale-handle detection.
static int FinishJoint( b3JointId jointId, b3WorldId worldId )
{
	for ( int i = 0; i < 8; ++i )
	{
		b3World_Step( worldId, 1.0f / 60.0f, 4 );
	}

	b3DestroyJoint( jointId, true );
	ENSURE( b3Joint_IsValid( jointId ) == false );

	b3DestroyWorld( worldId );
	return 0;
}

// Exercise the API shared by every joint type. Frames are saved and restored so
// the caller's setup survives.
static int ExerciseJointBase( b3JointId jointId, b3WorldId worldId, b3BodyId bodyIdA, b3BodyId bodyIdB, b3JointType expectedType )
{
	ENSURE( b3Joint_IsValid( jointId ) );
	ENSURE( b3Joint_GetType( jointId ) == expectedType );
	ENSURE( B3_ID_EQUALS( b3Joint_GetBodyA( jointId ), bodyIdA ) );
	ENSURE( B3_ID_EQUALS( b3Joint_GetBodyB( jointId ), bodyIdB ) );

	// B3_ID_EQUALS does not work for world ids
	b3WorldId gotWorld = b3Joint_GetWorld( jointId );
	ENSURE( gotWorld.index1 == worldId.index1 && gotWorld.generation == worldId.generation );

	b3Transform originalA = b3Joint_GetLocalFrameA( jointId );
	b3Transform originalB = b3Joint_GetLocalFrameB( jointId );

	b3Transform frameA = { { 0.1f, 0.2f, 0.3f }, b3Quat_identity };
	b3Joint_SetLocalFrameA( jointId, frameA );
	b3Transform gotA = b3Joint_GetLocalFrameA( jointId );
	ENSURE( gotA.p.x == frameA.p.x && gotA.p.y == frameA.p.y && gotA.p.z == frameA.p.z );

	b3Transform frameB = { { -0.4f, 0.5f, -0.6f }, b3Quat_identity };
	b3Joint_SetLocalFrameB( jointId, frameB );
	b3Transform gotB = b3Joint_GetLocalFrameB( jointId );
	ENSURE( gotB.p.x == frameB.p.x && gotB.p.y == frameB.p.y && gotB.p.z == frameB.p.z );

	b3Joint_SetCollideConnected( jointId, true );
	ENSURE( b3Joint_GetCollideConnected( jointId ) == true );
	b3Joint_SetCollideConnected( jointId, false );
	ENSURE( b3Joint_GetCollideConnected( jointId ) == false );

	int userData = 0;
	b3Joint_SetUserData( jointId, &userData );
	ENSURE( b3Joint_GetUserData( jointId ) == &userData );

	b3Joint_SetConstraintTuning( jointId, 90.0f, 3.0f );
	float hertz = 0.0f;
	float dampingRatio = 0.0f;
	b3Joint_GetConstraintTuning( jointId, &hertz, &dampingRatio );
	ENSURE( hertz == 90.0f );
	ENSURE( dampingRatio == 3.0f );

	b3Joint_SetForceThreshold( jointId, 100.0f );
	ENSURE( b3Joint_GetForceThreshold( jointId ) == 100.0f );

	b3Joint_SetTorqueThreshold( jointId, 200.0f );
	ENSURE( b3Joint_GetTorqueThreshold( jointId ) == 200.0f );

	b3Joint_WakeBodies( jointId );

	// No stable value to assert before the first step, call for coverage
	b3Vec3 force = b3Joint_GetConstraintForce( jointId );
	b3Vec3 torque = b3Joint_GetConstraintTorque( jointId );
	float linearSeparation = b3Joint_GetLinearSeparation( jointId );
	MAYBE_UNUSED( force );
	MAYBE_UNUSED( torque );
	MAYBE_UNUSED( linearSeparation );

	// Wheel joint angular separation is an unimplemented todo in joint.c that
	// asserts. Every other type computes it.
	if ( expectedType != b3_wheelJoint )
	{
		float angularSeparation = b3Joint_GetAngularSeparation( jointId );
		MAYBE_UNUSED( angularSeparation );
	}

	b3Joint_SetLocalFrameA( jointId, originalA );
	b3Joint_SetLocalFrameB( jointId, originalB );

	return 0;
}

static int TestParallelJoint( void )
{
	JointFixture f = CreateJointFixture();

	b3ParallelJointDef def = b3DefaultParallelJointDef();
	SetCommonFrames( &def.base, &f );
	def.hertz = 2.0f;
	def.dampingRatio = 0.5f;
	def.maxTorque = 100.0f;
	b3JointId jointId = b3CreateParallelJoint( f.worldId, &def );

	if ( ExerciseJointBase( jointId, f.worldId, f.groundId, f.bodyId, b3_parallelJoint ) != 0 )
	{
		return 1;
	}

	b3ParallelJoint_SetSpringHertz( jointId, 5.0f );
	ENSURE( b3ParallelJoint_GetSpringHertz( jointId ) == 5.0f );

	b3ParallelJoint_SetSpringDampingRatio( jointId, 0.7f );
	ENSURE( b3ParallelJoint_GetSpringDampingRatio( jointId ) == 0.7f );

	b3ParallelJoint_SetMaxTorque( jointId, 250.0f );
	ENSURE( b3ParallelJoint_GetMaxTorque( jointId ) == 250.0f );

	return FinishJoint( jointId, f.worldId );
}

static int TestDistanceJoint( void )
{
	JointFixture f = CreateJointFixture();

	b3DistanceJointDef def = b3DefaultDistanceJointDef();
	SetCommonFrames( &def.base, &f );
	def.length = 2.0f;
	b3JointId jointId = b3CreateDistanceJoint( f.worldId, &def );

	if ( ExerciseJointBase( jointId, f.worldId, f.groundId, f.bodyId, b3_distanceJoint ) != 0 )
	{
		return 1;
	}

	b3DistanceJoint_SetLength( jointId, 3.0f );
	ENSURE( b3DistanceJoint_GetLength( jointId ) == 3.0f );

	b3DistanceJoint_EnableSpring( jointId, true );
	ENSURE( b3DistanceJoint_IsSpringEnabled( jointId ) == true );

	b3DistanceJoint_SetSpringForceRange( jointId, -50.0f, 75.0f );
	float lowerForce = 0.0f;
	float upperForce = 0.0f;
	b3DistanceJoint_GetSpringForceRange( jointId, &lowerForce, &upperForce );
	ENSURE( lowerForce == -50.0f && upperForce == 75.0f );

	b3DistanceJoint_SetSpringHertz( jointId, 4.0f );
	ENSURE( b3DistanceJoint_GetSpringHertz( jointId ) == 4.0f );

	b3DistanceJoint_SetSpringDampingRatio( jointId, 0.6f );
	ENSURE( b3DistanceJoint_GetSpringDampingRatio( jointId ) == 0.6f );

	b3DistanceJoint_EnableLimit( jointId, true );
	ENSURE( b3DistanceJoint_IsLimitEnabled( jointId ) == true );

	b3DistanceJoint_SetLengthRange( jointId, 1.0f, 5.0f );
	ENSURE( b3DistanceJoint_GetMinLength( jointId ) == 1.0f );
	ENSURE( b3DistanceJoint_GetMaxLength( jointId ) == 5.0f );

	float currentLength = b3DistanceJoint_GetCurrentLength( jointId );
	MAYBE_UNUSED( currentLength );

	b3DistanceJoint_EnableMotor( jointId, true );
	ENSURE( b3DistanceJoint_IsMotorEnabled( jointId ) == true );

	b3DistanceJoint_SetMotorSpeed( jointId, 1.5f );
	ENSURE( b3DistanceJoint_GetMotorSpeed( jointId ) == 1.5f );

	b3DistanceJoint_SetMaxMotorForce( jointId, 25.0f );
	ENSURE( b3DistanceJoint_GetMaxMotorForce( jointId ) == 25.0f );

	float motorForce = b3DistanceJoint_GetMotorForce( jointId );
	MAYBE_UNUSED( motorForce );

	return FinishJoint( jointId, f.worldId );
}

static int TestFilterJoint( void )
{
	JointFixture f = CreateJointFixture();

	// The filter joint has no type-specific API. It only disables collision and
	// keeps both bodies in the same island.
	b3FilterJointDef def = b3DefaultFilterJointDef();
	def.base.bodyIdA = f.groundId;
	def.base.bodyIdB = f.bodyId;
	b3JointId jointId = b3CreateFilterJoint( f.worldId, &def );

	if ( ExerciseJointBase( jointId, f.worldId, f.groundId, f.bodyId, b3_filterJoint ) != 0 )
	{
		return 1;
	}

	return FinishJoint( jointId, f.worldId );
}

static int TestMotorJoint( void )
{
	JointFixture f = CreateJointFixture();

	b3MotorJointDef def = b3DefaultMotorJointDef();
	SetCommonFrames( &def.base, &f );
	b3JointId jointId = b3CreateMotorJoint( f.worldId, &def );

	if ( ExerciseJointBase( jointId, f.worldId, f.groundId, f.bodyId, b3_motorJoint ) != 0 )
	{
		return 1;
	}

	b3Vec3 linearVelocity = { 1.0f, 2.0f, 3.0f };
	b3MotorJoint_SetLinearVelocity( jointId, linearVelocity );
	b3Vec3 gotLinear = b3MotorJoint_GetLinearVelocity( jointId );
	ENSURE( gotLinear.x == 1.0f && gotLinear.y == 2.0f && gotLinear.z == 3.0f );

	b3Vec3 angularVelocity = { 0.1f, 0.2f, 0.3f };
	b3MotorJoint_SetAngularVelocity( jointId, angularVelocity );
	b3Vec3 gotAngular = b3MotorJoint_GetAngularVelocity( jointId );
	ENSURE( gotAngular.x == 0.1f && gotAngular.y == 0.2f && gotAngular.z == 0.3f );

	b3MotorJoint_SetMaxVelocityForce( jointId, 500.0f );
	ENSURE( b3MotorJoint_GetMaxVelocityForce( jointId ) == 500.0f );

	b3MotorJoint_SetMaxVelocityTorque( jointId, 600.0f );
	ENSURE( b3MotorJoint_GetMaxVelocityTorque( jointId ) == 600.0f );

	b3MotorJoint_SetLinearHertz( jointId, 3.0f );
	ENSURE( b3MotorJoint_GetLinearHertz( jointId ) == 3.0f );

	b3MotorJoint_SetLinearDampingRatio( jointId, 0.8f );
	ENSURE( b3MotorJoint_GetLinearDampingRatio( jointId ) == 0.8f );

	b3MotorJoint_SetAngularHertz( jointId, 4.0f );
	ENSURE( b3MotorJoint_GetAngularHertz( jointId ) == 4.0f );

	b3MotorJoint_SetAngularDampingRatio( jointId, 0.9f );
	ENSURE( b3MotorJoint_GetAngularDampingRatio( jointId ) == 0.9f );

	b3MotorJoint_SetMaxSpringForce( jointId, 700.0f );
	ENSURE( b3MotorJoint_GetMaxSpringForce( jointId ) == 700.0f );

	b3MotorJoint_SetMaxSpringTorque( jointId, 800.0f );
	ENSURE( b3MotorJoint_GetMaxSpringTorque( jointId ) == 800.0f );

	return FinishJoint( jointId, f.worldId );
}

static int TestPrismaticJoint( void )
{
	JointFixture f = CreateJointFixture();

	b3PrismaticJointDef def = b3DefaultPrismaticJointDef();
	SetCommonFrames( &def.base, &f );
	b3JointId jointId = b3CreatePrismaticJoint( f.worldId, &def );

	if ( ExerciseJointBase( jointId, f.worldId, f.groundId, f.bodyId, b3_prismaticJoint ) != 0 )
	{
		return 1;
	}

	b3PrismaticJoint_EnableSpring( jointId, true );
	ENSURE( b3PrismaticJoint_IsSpringEnabled( jointId ) == true );

	b3PrismaticJoint_SetSpringHertz( jointId, 5.0f );
	ENSURE( b3PrismaticJoint_GetSpringHertz( jointId ) == 5.0f );

	b3PrismaticJoint_SetSpringDampingRatio( jointId, 0.5f );
	ENSURE( b3PrismaticJoint_GetSpringDampingRatio( jointId ) == 0.5f );

	b3PrismaticJoint_SetTargetTranslation( jointId, 1.0f );
	ENSURE( b3PrismaticJoint_GetTargetTranslation( jointId ) == 1.0f );

	b3PrismaticJoint_EnableLimit( jointId, true );
	ENSURE( b3PrismaticJoint_IsLimitEnabled( jointId ) == true );

	b3PrismaticJoint_SetLimits( jointId, -2.0f, 2.0f );
	ENSURE( b3PrismaticJoint_GetLowerLimit( jointId ) == -2.0f );
	ENSURE( b3PrismaticJoint_GetUpperLimit( jointId ) == 2.0f );

	b3PrismaticJoint_EnableMotor( jointId, true );
	ENSURE( b3PrismaticJoint_IsMotorEnabled( jointId ) == true );

	b3PrismaticJoint_SetMotorSpeed( jointId, 1.5f );
	ENSURE( b3PrismaticJoint_GetMotorSpeed( jointId ) == 1.5f );

	b3PrismaticJoint_SetMaxMotorForce( jointId, 30.0f );
	ENSURE( b3PrismaticJoint_GetMaxMotorForce( jointId ) == 30.0f );

	float motorForce = b3PrismaticJoint_GetMotorForce( jointId );
	float translation = b3PrismaticJoint_GetTranslation( jointId );
	float speed = b3PrismaticJoint_GetSpeed( jointId );
	MAYBE_UNUSED( motorForce );
	MAYBE_UNUSED( translation );
	MAYBE_UNUSED( speed );

	return FinishJoint( jointId, f.worldId );
}

static int TestRevoluteJoint( void )
{
	JointFixture f = CreateJointFixture();

	b3RevoluteJointDef def = b3DefaultRevoluteJointDef();
	SetCommonFrames( &def.base, &f );
	b3JointId jointId = b3CreateRevoluteJoint( f.worldId, &def );

	if ( ExerciseJointBase( jointId, f.worldId, f.groundId, f.bodyId, b3_revoluteJoint ) != 0 )
	{
		return 1;
	}

	b3RevoluteJoint_EnableSpring( jointId, true );
	ENSURE( b3RevoluteJoint_IsSpringEnabled( jointId ) == true );

	b3RevoluteJoint_SetSpringHertz( jointId, 5.0f );
	ENSURE( b3RevoluteJoint_GetSpringHertz( jointId ) == 5.0f );

	b3RevoluteJoint_SetSpringDampingRatio( jointId, 0.5f );
	ENSURE( b3RevoluteJoint_GetSpringDampingRatio( jointId ) == 0.5f );

	b3RevoluteJoint_SetTargetAngle( jointId, 0.5f );
	ENSURE( b3RevoluteJoint_GetTargetAngle( jointId ) == 0.5f );

	float angle = b3RevoluteJoint_GetAngle( jointId );
	MAYBE_UNUSED( angle );

	b3RevoluteJoint_EnableLimit( jointId, true );
	ENSURE( b3RevoluteJoint_IsLimitEnabled( jointId ) == true );

	b3RevoluteJoint_SetLimits( jointId, -1.0f, 1.0f );
	ENSURE( b3RevoluteJoint_GetLowerLimit( jointId ) == -1.0f );
	ENSURE( b3RevoluteJoint_GetUpperLimit( jointId ) == 1.0f );

	b3RevoluteJoint_EnableMotor( jointId, true );
	ENSURE( b3RevoluteJoint_IsMotorEnabled( jointId ) == true );

	b3RevoluteJoint_SetMotorSpeed( jointId, 2.0f );
	ENSURE( b3RevoluteJoint_GetMotorSpeed( jointId ) == 2.0f );

	b3RevoluteJoint_SetMaxMotorTorque( jointId, 40.0f );
	ENSURE( b3RevoluteJoint_GetMaxMotorTorque( jointId ) == 40.0f );

	float motorTorque = b3RevoluteJoint_GetMotorTorque( jointId );
	MAYBE_UNUSED( motorTorque );

	ENSURE( b3RevoluteJoint_GetArmature( jointId ) == 0.0f );
	b3RevoluteJoint_SetArmature( jointId, 0.25f );
	ENSURE( b3RevoluteJoint_GetArmature( jointId ) == 0.25f );

	return FinishJoint( jointId, f.worldId );
}

static int TestSphericalJoint( void )
{
	JointFixture f = CreateJointFixture();

	b3SphericalJointDef def = b3DefaultSphericalJointDef();
	SetCommonFrames( &def.base, &f );
	b3JointId jointId = b3CreateSphericalJoint( f.worldId, &def );

	if ( ExerciseJointBase( jointId, f.worldId, f.groundId, f.bodyId, b3_sphericalJoint ) != 0 )
	{
		return 1;
	}

	b3SphericalJoint_EnableConeLimit( jointId, true );
	ENSURE( b3SphericalJoint_IsConeLimitEnabled( jointId ) == true );

	b3SphericalJoint_SetConeLimit( jointId, 0.5f );
	ENSURE( b3SphericalJoint_GetConeLimit( jointId ) == 0.5f );

	float coneAngle = b3SphericalJoint_GetConeAngle( jointId );
	MAYBE_UNUSED( coneAngle );

	b3SphericalJoint_EnableTwistLimit( jointId, true );
	ENSURE( b3SphericalJoint_IsTwistLimitEnabled( jointId ) == true );

	b3SphericalJoint_SetTwistLimits( jointId, -0.5f, 0.5f );
	ENSURE( b3SphericalJoint_GetLowerTwistLimit( jointId ) == -0.5f );
	ENSURE( b3SphericalJoint_GetUpperTwistLimit( jointId ) == 0.5f );

	float twistAngle = b3SphericalJoint_GetTwistAngle( jointId );
	MAYBE_UNUSED( twistAngle );

	b3SphericalJoint_EnableSpring( jointId, true );
	ENSURE( b3SphericalJoint_IsSpringEnabled( jointId ) == true );

	b3SphericalJoint_SetSpringHertz( jointId, 5.0f );
	ENSURE( b3SphericalJoint_GetSpringHertz( jointId ) == 5.0f );

	b3SphericalJoint_SetSpringDampingRatio( jointId, 0.5f );
	ENSURE( b3SphericalJoint_GetSpringDampingRatio( jointId ) == 0.5f );

	// 90 degrees about z, a unit quaternion that round-trips through storage
	b3Quat targetRotation = { { 0.0f, 0.0f, 0.7071068f }, 0.7071068f };
	b3SphericalJoint_SetTargetRotation( jointId, targetRotation );
	b3Quat gotRotation = b3SphericalJoint_GetTargetRotation( jointId );
	ENSURE_SMALL( gotRotation.v.x - targetRotation.v.x, 1.0e-5f );
	ENSURE_SMALL( gotRotation.v.y - targetRotation.v.y, 1.0e-5f );
	ENSURE_SMALL( gotRotation.v.z - targetRotation.v.z, 1.0e-5f );
	ENSURE_SMALL( gotRotation.s - targetRotation.s, 1.0e-5f );

	b3SphericalJoint_EnableMotor( jointId, true );
	ENSURE( b3SphericalJoint_IsMotorEnabled( jointId ) == true );

	b3Vec3 motorVelocity = { 0.1f, 0.2f, 0.3f };
	b3SphericalJoint_SetMotorVelocity( jointId, motorVelocity );
	b3Vec3 gotMotorVelocity = b3SphericalJoint_GetMotorVelocity( jointId );
	ENSURE( gotMotorVelocity.x == 0.1f && gotMotorVelocity.y == 0.2f && gotMotorVelocity.z == 0.3f );

	b3SphericalJoint_SetMaxMotorTorque( jointId, 50.0f );
	ENSURE( b3SphericalJoint_GetMaxMotorTorque( jointId ) == 50.0f );

	b3Vec3 motorTorque = b3SphericalJoint_GetMotorTorque( jointId );
	MAYBE_UNUSED( motorTorque );

	ENSURE( b3SphericalJoint_IsEllipticalConeEnabled( jointId ) == false );
	b3SphericalJoint_EnableEllipticalCone( jointId, true );
	ENSURE( b3SphericalJoint_IsEllipticalConeEnabled( jointId ) == true );

	b3SphericalJoint_SetEllipticalConeLimits( jointId, 0.4f, 1.8f );
	ENSURE( b3SphericalJoint_GetConeLimitX( jointId ) == 0.4f );
	ENSURE( b3SphericalJoint_GetConeLimitY( jointId ) == 1.8f );

	// Clamped below a swing of pi, where the tilt is singular
	b3SphericalJoint_SetEllipticalConeLimits( jointId, 3.0f, -1.0f );
	ENSURE( b3SphericalJoint_GetConeLimitX( jointId ) == 0.9f * B3_PI );
	ENSURE( b3SphericalJoint_GetConeLimitY( jointId ) == 0.0f );
	b3SphericalJoint_SetEllipticalConeLimits( jointId, 0.4f, 1.8f );

	b3Vec2 coneAngles = b3SphericalJoint_GetConeAngles( jointId );
	MAYBE_UNUSED( coneAngles );

	ENSURE( b3SphericalJoint_IsAsymmetricConeEnabled( jointId ) == false );
	b3SphericalJoint_EnableAsymmetricCone( jointId, true );
	ENSURE( b3SphericalJoint_IsAsymmetricConeEnabled( jointId ) == true );

	b3SphericalJoint_SetAsymmetricConeLimits( jointId, 2.0f, 0.3f, 0.7f, 0.45f );
	ENSURE( b3SphericalJoint_GetConeLimitX( jointId ) == 2.0f );
	ENSURE( b3SphericalJoint_GetConeLimitNegativeX( jointId ) == 0.3f );
	ENSURE( b3SphericalJoint_GetConeLimitY( jointId ) == 0.7f );
	ENSURE( b3SphericalJoint_GetConeLimitNegativeY( jointId ) == 0.45f );

	// The symmetric setter keeps the -x and -y limits
	b3SphericalJoint_SetEllipticalConeLimits( jointId, 0.4f, 1.8f );
	ENSURE( b3SphericalJoint_GetConeLimitNegativeX( jointId ) == 0.3f );
	ENSURE( b3SphericalJoint_GetConeLimitNegativeY( jointId ) == 0.45f );

	// Clamped like the elliptical cone
	b3SphericalJoint_SetAsymmetricConeLimits( jointId, 0.4f, 3.0f, 1.8f, -1.0f );
	ENSURE( b3SphericalJoint_GetConeLimitNegativeX( jointId ) == 0.9f * B3_PI );
	ENSURE( b3SphericalJoint_GetConeLimitNegativeY( jointId ) == 0.0f );
	b3SphericalJoint_SetAsymmetricConeLimits( jointId, 0.4f, 0.3f, 1.8f, 0.45f );

	ENSURE( b3SphericalJoint_GetArmature( jointId ) == 0.0f );
	b3SphericalJoint_SetArmature( jointId, 0.25f );
	ENSURE( b3SphericalJoint_GetArmature( jointId ) == 0.25f );

	return FinishJoint( jointId, f.worldId );
}

// A unit cube of density 1 pinned at its center: the inertia about any axis through the
// pivot is 1/6. A constant torque spins it up at torque / (1/6 + armature), at any sub-step count.
static int TestArmatureAcceleration( void )
{
	const float inertia = 1.0f / 6.0f;
	const float armature = 0.5f;
	const float torque = 2.0f;
	int subStepCounts[] = { 1, 4, 8 };

	for ( int typeIndex = 0; typeIndex < 2; ++typeIndex )
	{
		for ( int i = 0; i < 3; ++i )
		{
			JointFixture f = CreateJointFixture();

			b3JointId jointId;
			b3Vec3 axis;
			if ( typeIndex == 0 )
			{
				b3RevoluteJointDef def = b3DefaultRevoluteJointDef();
				SetCommonFrames( &def.base, &f );
				def.armature = armature;
				jointId = b3CreateRevoluteJoint( f.worldId, &def );
				axis = b3Vec3_axisZ;
			}
			else
			{
				b3SphericalJointDef def = b3DefaultSphericalJointDef();
				SetCommonFrames( &def.base, &f );
				def.armature = armature;
				jointId = b3CreateSphericalJoint( f.worldId, &def );
				axis = b3Normalize( (b3Vec3){ 1.0f, 2.0f, 3.0f } );
			}

			float timeStep = 1.0f / 60.0f;
			for ( int step = 0; step < 60; ++step )
			{
				b3Body_ApplyTorque( f.bodyId, b3MulSV( torque, axis ), true );
				b3World_Step( f.worldId, timeStep, subStepCounts[i] );
			}

			float expected = torque * 60.0f * timeStep / ( inertia + armature );
			b3Vec3 w = b3Body_GetAngularVelocity( f.bodyId );
			ENSURE_SMALL( b3Dot( w, axis ) - expected, 1.0e-3f * expected );
			ENSURE_SMALL( b3Length( b3Sub( w, b3MulSV( b3Dot( w, axis ), axis ) ) ), 1.0e-3f * expected );

			// The armature torque reported by the joint balances part of the applied torque
			b3Vec3 jointTorque = b3Joint_GetConstraintTorque( jointId );
			MAYBE_UNUSED( jointTorque );

			b3DestroyWorld( f.worldId );
		}
	}

	return 0;
}

// Energy of a five link pendulum with armature on every hinge never rises above its start. The
// armature stores kinetic energy 0.5 * armature * w^2 for the hinge speed w, counted from the bodies.
static int TestArmatureEnergy( void )
{
	enum
	{
		e_count = 5
	};

	int subStepCounts[] = { 1, 4, 16 };
	float armatures[] = { 0.2f, 2.0f };
	for ( int a = 0; a < 2; ++a )
	{
		for ( int i = 0; i < 3; ++i )
		{
			b3WorldDef worldDef = b3DefaultWorldDef();
			worldDef.gravity = (b3Vec3){ 0.0f, -10.0f, 0.0f };
			b3WorldId worldId = b3CreateWorld( &worldDef );

			b3BodyDef groundDef = b3DefaultBodyDef();
			b3BodyId groundId = b3CreateBody( worldId, &groundDef );

			b3ShapeDef shapeDef = b3DefaultShapeDef();
			shapeDef.density = 1000.0f;
			shapeDef.filter.groupIndex = -1;
			b3Capsule capsule = { { -0.45f, 0.0f, 0.0f }, { 0.45f, 0.0f, 0.0f }, 0.05f };

			float armature = armatures[a];
			b3BodyId bodyIds[e_count];
			b3BodyId prevId = groundId;
			b3Vec3 prevAnchor = { 0.0f, 0.0f, 0.0f };
			for ( int k = 0; k < e_count; ++k )
			{
				b3BodyDef bodyDef = b3DefaultBodyDef();
				bodyDef.type = b3_dynamicBody;
				bodyDef.position = (b3Pos){ 0.5f + k, 0.0f, 0.0f };
				bodyIds[k] = b3CreateBody( worldId, &bodyDef );
				b3CreateCapsuleShape( bodyIds[k], &shapeDef, &capsule );

				b3RevoluteJointDef def = b3DefaultRevoluteJointDef();
				def.base.bodyIdA = prevId;
				def.base.bodyIdB = bodyIds[k];
				def.base.localFrameA.p = prevAnchor;
				def.base.localFrameB.p = (b3Vec3){ -0.5f, 0.0f, 0.0f };
				def.armature = armature;
				b3CreateRevoluteJoint( worldId, &def );
				prevId = bodyIds[k];
				prevAnchor = (b3Vec3){ 0.5f, 0.0f, 0.0f };
			}

			// Energy scale: the chain's weight times its length
			float scale = 10.0f * e_count * b3Body_GetMass( bodyIds[0] ) * e_count;

			float maxEnergy = -FLT_MAX;
			float startEnergy = 0.0f;
			for ( int step = 0; step <= 600; ++step )
			{
				float energy = 0.0f;
				for ( int k = 0; k < e_count; ++k )
				{
					b3MassData massData = b3Body_GetMassData( bodyIds[k] );
					b3Vec3 v = b3Body_GetLinearVelocity( bodyIds[k] );
					b3Vec3 w = b3Body_GetAngularVelocity( bodyIds[k] );
					b3Pos p = b3Body_GetWorldCenter( bodyIds[k] );
					ENSURE( b3IsValidVec3( v ) && b3IsValidVec3( w ) );

					// Rotation stays about z, so the inertia about z is enough
					float wPrev = k == 0 ? 0.0f : b3Body_GetAngularVelocity( bodyIds[k - 1] ).z;
					energy += 0.5f * massData.mass * b3Dot( v, v ) + 0.5f * massData.inertia.cz.z * w.z * w.z;
					energy += massData.mass * 10.0f * (float)p.y;
					energy += 0.5f * armature * ( w.z - wPrev ) * ( w.z - wPrev );
				}

				if ( step == 0 )
				{
					startEnergy = energy;
				}
				maxEnergy = b3MaxFloat( maxEnergy, energy );

				b3World_Step( worldId, 1.0f / 60.0f, subStepCounts[i] );
			}

			// Without armature the solver itself drifts by up to about 0.2 % of the scale here
			ENSURE( maxEnergy <= startEnergy + 0.005f * scale );

			b3DestroyWorld( worldId );
		}
	}

	return 0;
}

// Axis-angle rotation with the C library sine and cosine. b3MakeQuatFromAxisAngle uses a fast
// approximation, which is too coarse for checking the constraint against finite differences.
static b3Quat MakeExactQuat( b3Vec3 axis, float radians )
{
	float s = sinf( 0.5f * radians );
	return (b3Quat){ { s * axis.x, s * axis.y, s * axis.z }, cosf( 0.5f * radians ) };
}

// Build a relative rotation from a tilt (swing angle times the direction the z-axis tips towards)
// and a twist about z.
static b3Quat MakeTiltTwist( float tiltX, float tiltY, float twist )
{
	float swingAngle = sqrtf( tiltX * tiltX + tiltY * tiltY );
	b3Quat swing = b3Quat_identity;
	if ( swingAngle > 0.0f )
	{
		b3Vec3 axis = { -tiltY / swingAngle, tiltX / swingAngle, 0.0f };
		swing = MakeExactQuat( axis, swingAngle );
	}

	return b3MulQuat( swing, MakeExactQuat( b3Vec3_axisZ, twist ) );
}

// Checks the elliptical cone constraint against finite differences, on the ellipse and with twist,
// including cones wider than a hemisphere, and that a circle reduces to angle - swing.
static int TestEllipticalConeJacobian( void )
{
	float limits[][2] = { { 0.4f, 1.2f }, { 1.9f, 0.6f }, { 0.7f, 0.7f }, { 2.4f, 1.5f } };
	float twists[] = { 0.0f, 0.8f, -2.0f };
	b3Vec3 rates[] = { { 1.0f, 0.0f, 0.0f }, { 0.0f, 1.0f, 0.0f }, { 0.0f, 0.0f, 1.0f }, { 0.3f, -0.5f, 0.8f } };
	const float delta = 1.0e-3f;

	for ( int l = 0; l < 4; ++l )
	{
		float angleX = limits[l][0];
		float angleY = limits[l][1];
		for ( int t = 0; t < 3; ++t )
		{
			for ( int p = 0; p < 12; ++p )
			{
				float phi = 0.3f + p * 2.0f * B3_PI / 12.0f;
				b3Quat q = MakeTiltTwist( angleX * cosf( phi ), angleY * sinf( phi ), twists[t] );

				b3Vec3 jacobian;
				float c = b3GetEllipticalConeConstraint( q, angleX, angleY, &jacobian );
				ENSURE_SMALL( c, 1.0e-4f );

				b3Vec2 tilt = b3GetSwingTilt( q );
				ENSURE_SMALL( tilt.x - angleX * cosf( phi ), 1.0e-4f );
				ENSURE_SMALL( tilt.y - angleY * sinf( phi ), 1.0e-4f );

				for ( int r = 0; r < 4; ++r )
				{
					// q' = exp(w * dt) * q for a relative angular velocity w in frameA coordinates
					b3Vec3 w = rates[r];
					float wLength = b3Length( w );
					b3Vec3 wAxis = b3MulSV( 1.0f / wLength, w );
					b3Quat qPlus = b3MulQuat( MakeExactQuat( wAxis, wLength * delta ), q );
					b3Quat qMinus = b3MulQuat( MakeExactQuat( wAxis, -wLength * delta ), q );

					b3Vec3 unused;
					float cPlus = b3GetEllipticalConeConstraint( qPlus, angleX, angleY, &unused );
					float cMinus = b3GetEllipticalConeConstraint( qMinus, angleX, angleY, &unused );
					float rate = ( cPlus - cMinus ) / ( 2.0f * delta );
					ENSURE_SMALL( rate + b3Dot( jacobian, w ), 2.0e-2f * ( 1.0f + b3Length( jacobian ) ) );
				}
			}
		}
	}

	// A circle is the circular cone
	for ( int p = 0; p < 8; ++p )
	{
		float phi = p * 0.7f;
		float swingAngle = 0.1f + 0.2f * p;
		b3Quat q = MakeTiltTwist( swingAngle * cosf( phi ), swingAngle * sinf( phi ), 0.5f );
		b3Vec3 jacobian;
		float c = b3GetEllipticalConeConstraint( q, 0.9f, 0.9f, &jacobian );
		ENSURE_SMALL( c - ( 0.9f - b3GetSwingAngle( q ) ), 1.0e-4f );
		ENSURE_SMALL( b3Length( jacobian ) - 1.0f, 1.0e-4f );
	}

	return 0;
}

// A ball joint driven by a motor into its elliptical cone comes to rest on the ellipse, also for a
// cone wider than a hemisphere, and an elliptical cone with equal angles matches the circular cone.
static int TestEllipticalConeLimit( void )
{
	// motor axis (frameA = world), cone angles, expected tilt (x, y), or a negative x to check the ellipse only
	struct
	{
		b3Vec3 motor;
		float angleX, angleY;
		float tiltX, tiltY;
	} cases[] = {
		{ { 0.0f, 1.0f, 0.0f }, 0.4f, 1.2f, 0.4f, 0.0f },	// tip towards +x
		{ { -1.0f, 0.0f, 0.0f }, 0.4f, 1.2f, 0.0f, 1.2f },	// tip towards +y
		{ { 0.0f, -1.0f, 0.0f }, 2.0f, 0.5f, -2.0f, 0.0f }, // tip towards -x, past a hemisphere
		{ { -1.0f, 1.0f, 0.0f }, 0.4f, 1.2f, -1.0f, -1.0f },
	};

	for ( int i = 0; i < 4; ++i )
	{
		JointFixture f = CreateJointFixture();

		b3SphericalJointDef def = b3DefaultSphericalJointDef();
		SetCommonFrames( &def.base, &f );
		def.enableConeLimit = true;
		def.enableEllipticalCone = true;
		def.coneAngleX = cases[i].angleX;
		def.coneAngleY = cases[i].angleY;
		def.enableMotor = true;
		def.motorVelocity = b3MulSV( 2.0f, cases[i].motor );
		def.maxMotorTorque = 2.0f;
		b3JointId jointId = b3CreateSphericalJoint( f.worldId, &def );

		for ( int step = 0; step < 240; ++step )
		{
			b3World_Step( f.worldId, 1.0f / 60.0f, 4 );
		}

		b3Vec2 tilt = b3SphericalJoint_GetConeAngles( jointId );
		if ( cases[i].tiltX != -1.0f || cases[i].tiltY != -1.0f )
		{
			ENSURE_SMALL( tilt.x - cases[i].tiltX, 0.02f );
			ENSURE_SMALL( tilt.y - cases[i].tiltY, 0.02f );
		}

		float u = tilt.x / cases[i].angleX;
		float v = tilt.y / cases[i].angleY;
		ENSURE_SMALL( sqrtf( u * u + v * v ) - 1.0f, 0.03f );
		ENSURE( b3Joint_GetAngularSeparation( jointId ) < 0.02f );

		b3DestroyWorld( f.worldId );
	}

	// Equal angles: same rest swing as the circular cone
	float swing[2];
	for ( int elliptical = 0; elliptical < 2; ++elliptical )
	{
		JointFixture f = CreateJointFixture();

		b3SphericalJointDef def = b3DefaultSphericalJointDef();
		SetCommonFrames( &def.base, &f );
		def.enableConeLimit = true;
		def.coneAngle = 0.7f;
		def.enableEllipticalCone = elliptical == 1;
		def.coneAngleX = 0.7f;
		def.coneAngleY = 0.7f;
		def.enableMotor = true;
		def.motorVelocity = (b3Vec3){ -1.0f, 2.0f, 0.5f };
		def.maxMotorTorque = 2.0f;
		b3JointId jointId = b3CreateSphericalJoint( f.worldId, &def );

		for ( int step = 0; step < 240; ++step )
		{
			b3World_Step( f.worldId, 1.0f / 60.0f, 4 );
		}

		swing[elliptical] = b3SphericalJoint_GetConeAngle( jointId );
		b3DestroyWorld( f.worldId );
	}

	ENSURE_SMALL( swing[0] - swing[1], 0.01f );
	ENSURE_SMALL( swing[1] - 0.7f, 0.02f );

	return 0;
}

// The semi-axes of the quarter-ellipse of an asymmetric cone for a tilt direction (limits: +x, -x, +y, -y)
static float AsymmetricConeG( const float* limits, float tiltX, float tiltY )
{
	float u = tiltX / ( tiltX >= 0.0f ? limits[0] : limits[1] );
	float v = tiltY / ( tiltY >= 0.0f ? limits[2] : limits[3] );
	return sqrtf( u * u + v * v );
}

// Checks the asymmetric cone constraint against finite differences in all four quadrants, including lopsided
// cones wider than a hemisphere; that the constraint and its Jacobian are continuous across the axes, where two
// quarter-ellipses meet; and that symmetric pairs give the elliptical cone exactly.
static int TestAsymmetricConeJacobian( void )
{
	// +x, -x, +y, -y
	float limits[][4] = {
		{ 2.09f, 0.35f, 0.79f, 0.52f },
		{ 0.4f, 1.2f, 1.5f, 0.3f },
		{ 2.6f, 2.2f, 0.9f, 2.5f },
		{ 0.7f, 0.2f, 0.7f, 0.2f },
	};
	float twists[] = { 0.0f, 0.8f, -2.0f };
	b3Vec3 rates[] = { { 1.0f, 0.0f, 0.0f }, { 0.0f, 1.0f, 0.0f }, { 0.0f, 0.0f, 1.0f }, { 0.3f, -0.5f, 0.8f } };
	const float delta = 1.0e-3f;

	for ( int l = 0; l < 4; ++l )
	{
		const float* lim = limits[l];
		for ( int t = 0; t < 3; ++t )
		{
			// On the boundary, in every quadrant
			for ( int p = 0; p < 16; ++p )
			{
				float phi = 0.2f + p * 2.0f * B3_PI / 16.0f;
				float cosPhi = cosf( phi );
				float sinPhi = sinf( phi );
				float tiltX = ( cosPhi >= 0.0f ? lim[0] : lim[1] ) * cosPhi;
				float tiltY = ( sinPhi >= 0.0f ? lim[2] : lim[3] ) * sinPhi;
				b3Quat q = MakeTiltTwist( tiltX, tiltY, twists[t] );

				b3Vec3 jacobian;
				float c = b3GetAsymmetricConeConstraint( q, lim[0], lim[1], lim[2], lim[3], &jacobian );
				ENSURE_SMALL( c, 1.0e-4f );

				b3Vec2 tilt = b3GetSwingTilt( q );
				ENSURE_SMALL( tilt.x - tiltX, 1.0e-4f );
				ENSURE_SMALL( tilt.y - tiltY, 1.0e-4f );

				for ( int r = 0; r < 4; ++r )
				{
					b3Vec3 w = rates[r];
					float wLength = b3Length( w );
					b3Vec3 wAxis = b3MulSV( 1.0f / wLength, w );
					b3Quat qPlus = b3MulQuat( MakeExactQuat( wAxis, wLength * delta ), q );
					b3Quat qMinus = b3MulQuat( MakeExactQuat( wAxis, -wLength * delta ), q );

					b3Vec3 unused;
					float cPlus = b3GetAsymmetricConeConstraint( qPlus, lim[0], lim[1], lim[2], lim[3], &unused );
					float cMinus = b3GetAsymmetricConeConstraint( qMinus, lim[0], lim[1], lim[2], lim[3], &unused );
					float rate = ( cPlus - cMinus ) / ( 2.0f * delta );
					ENSURE_SMALL( rate + b3Dot( jacobian, w ), 2.0e-2f * ( 1.0f + b3Length( jacobian ) ) );
				}
			}

			// Across each axis: on the boundary, and inside and outside it, a hair either side of the axis
			for ( int k = 0; k < 4; ++k )
			{
				float axisX = k == 0 ? 1.0f : ( k == 2 ? -1.0f : 0.0f );
				float axisY = k == 1 ? 1.0f : ( k == 3 ? -1.0f : 0.0f );
				float axisLimit = lim[k == 0 ? 0 : ( k == 1 ? 2 : ( k == 2 ? 1 : 3 ) )];
				float scales[] = { 0.5f, 1.0f, 1.3f };
				for ( int sc = 0; sc < 3; ++sc )
				{
					// Below a swing of pi, where the tilt wraps around
					float radius = b3MinFloat( scales[sc] * axisLimit, 2.8f );
					float side = 1.0e-4f;
					b3Quat qA = MakeTiltTwist( radius * axisX - side * axisY, radius * axisY + side * axisX, twists[t] );
					b3Quat qB = MakeTiltTwist( radius * axisX + side * axisY, radius * axisY - side * axisX, twists[t] );

					b3Vec3 jacobianA, jacobianB;
					float cA = b3GetAsymmetricConeConstraint( qA, lim[0], lim[1], lim[2], lim[3], &jacobianA );
					float cB = b3GetAsymmetricConeConstraint( qB, lim[0], lim[1], lim[2], lim[3], &jacobianB );
					ENSURE_SMALL( cA - cB, 1.0e-3f );
					ENSURE_SMALL( b3Length( b3Sub( jacobianA, jacobianB ) ), 1.0e-2f );

					// On the axis the constraint is the radial distance to that axis limit
					ENSURE_SMALL( cA - ( axisLimit - radius ), 1.0e-3f );
				}
			}
		}
	}

	// Symmetric pairs: the elliptical cone, bit for bit
	for ( int p = 0; p < 24; ++p )
	{
		float phi = 0.13f + p * 0.71f;
		float swingAngle = 0.05f + 0.11f * p;
		b3Quat q = MakeTiltTwist( swingAngle * cosf( phi ), swingAngle * sinf( phi ), 0.3f * p - 3.0f );
		b3Vec3 jacobianE, jacobianA;
		float cE = b3GetEllipticalConeConstraint( q, 0.6f, 1.7f, &jacobianE );
		float cA = b3GetAsymmetricConeConstraint( q, 0.6f, 0.6f, 1.7f, 1.7f, &jacobianA );
		ENSURE( cE == cA );
		ENSURE( jacobianE.x == jacobianA.x && jacobianE.y == jacobianA.y && jacobianE.z == jacobianA.z );
	}

	return 0;
}

// A ball joint driven by a motor into its asymmetric cone holds on the boundary in every quadrant and on
// every axis (each axis at its own limit), slides smoothly along the boundary across all four axes when
// the motor turns, follows a limit changed live, and with symmetric pairs steps exactly like the
// elliptical cone. The rest pose (tilt 0) is inside, so an undriven joint does not move.
static int TestAsymmetricConeLimit( void )
{
	// A lopsided cone like a hip: +x, -x, +y, -y
	const float limits[4] = { 2.0f, 0.35f, 0.8f, 0.5f };

	// Boundary hold: tilt directions on the axes (even) and in each quadrant (odd), counterclockwise from +x
	for ( int i = 0; i < 8; ++i )
	{
		float angle = 0.25f * B3_PI * i;
		b3Vec2 direction = { cosf( angle ), sinf( angle ) };
		if ( i % 2 == 0 )
		{
			// Exactly on the axis
			direction.x = b3AbsFloat( direction.x ) < 0.5f ? 0.0f : direction.x;
			direction.y = b3AbsFloat( direction.y ) < 0.5f ? 0.0f : direction.y;
		}

		JointFixture f = CreateJointFixture();

		b3SphericalJointDef def = b3DefaultSphericalJointDef();
		SetCommonFrames( &def.base, &f );
		def.enableConeLimit = true;
		def.enableEllipticalCone = true;
		def.enableAsymmetricCone = true;
		def.coneAngleX = limits[0];
		def.coneAngleNegativeX = limits[1];
		def.coneAngleY = limits[2];
		def.coneAngleNegativeY = limits[3];
		def.enableMotor = true;

		// A twist limit, or the part of the motor rotation the cone blocks becomes twist
		def.enableTwistLimit = true;
		def.lowerTwistAngle = -0.1f;
		def.upperTwistAngle = 0.1f;

		// A rotation about (-dy, dx, 0) tips the frameB z-axis towards (dx, dy)
		def.motorVelocity = (b3Vec3){ -2.0f * direction.y, 2.0f * direction.x, 0.0f };
		def.maxMotorTorque = 2.0f;
		b3JointId jointId = b3CreateSphericalJoint( f.worldId, &def );

		for ( int step = 0; step < 240; ++step )
		{
			b3World_Step( f.worldId, 1.0f / 60.0f, 4 );
		}

		b3Vec2 tilt = b3SphericalJoint_GetConeAngles( jointId );
		if ( i % 2 == 0 )
		{
			// On an axis: exactly that axis limit
			float axisLimit = direction.x > 0.5f
								  ? limits[0]
								  : ( direction.x < -0.5f ? limits[1] : ( direction.y > 0.5f ? limits[2] : limits[3] ) );
			ENSURE_SMALL( tilt.x - axisLimit * direction.x, 0.02f );
			ENSURE_SMALL( tilt.y - axisLimit * direction.y, 0.02f );
		}
		else
		{
			// Still in its quadrant
			ENSURE( tilt.x * direction.x > 0.0f && tilt.y * direction.y > 0.0f );
		}

		ENSURE_SMALL( AsymmetricConeG( limits, tilt.x, tilt.y ) - 1.0f, 0.03f );
		ENSURE( b3Joint_GetAngularSeparation( jointId ) < 0.02f );

		b3DestroyWorld( f.worldId );
	}

	// Quadrant crossing: the motor turns once around, the tilt slides along the boundary through all four
	// quadrants without leaving it or jumping
	for ( int subStep = 4; subStep <= 8; subStep += 4 )
	{
		JointFixture f = CreateJointFixture();

		b3SphericalJointDef def = b3DefaultSphericalJointDef();
		SetCommonFrames( &def.base, &f );
		def.enableConeLimit = true;
		def.enableEllipticalCone = true;
		def.enableAsymmetricCone = true;
		def.coneAngleX = limits[0];
		def.coneAngleNegativeX = limits[1];
		def.coneAngleY = limits[2];
		def.coneAngleNegativeY = limits[3];
		def.enableMotor = true;
		def.motorVelocity = (b3Vec3){ 0.0f, 2.0f, 0.0f };
		def.maxMotorTorque = 2.0f;
		def.enableTwistLimit = true;
		def.lowerTwistAngle = -0.1f;
		def.upperTwistAngle = 0.1f;
		b3JointId jointId = b3CreateSphericalJoint( f.worldId, &def );

		// Setting the motor velocity does not wake the body
		b3Body_EnableSleep( f.bodyId, false );

		const int settleSteps = 120;
		const int turnSteps = 1440;
		int quadrants = 0;
		float maxDeviation = 0.0f;
		float maxJump = 0.0f;
		b3Vec2 previous = { 0.0f, 0.0f };
		for ( int step = 0; step < settleSteps + turnSteps; ++step )
		{
			if ( step >= settleSteps )
			{
				float angle = 2.0f * B3_PI * ( step - settleSteps ) / turnSteps;
				b3Vec2 direction = { cosf( angle ), sinf( angle ) };
				b3SphericalJoint_SetMotorVelocity( jointId, (b3Vec3){ -2.0f * direction.y, 2.0f * direction.x, 0.0f } );
			}

			b3World_Step( f.worldId, 1.0f / 60.0f, subStep );

			b3Vec2 tilt = b3SphericalJoint_GetConeAngles( jointId );
			ENSURE( b3IsValidFloat( tilt.x ) && b3IsValidFloat( tilt.y ) );
			if ( step >= settleSteps )
			{
				maxDeviation = b3MaxFloat( maxDeviation, b3AbsFloat( AsymmetricConeG( limits, tilt.x, tilt.y ) - 1.0f ) );
				float jumpX = tilt.x - previous.x;
				float jumpY = tilt.y - previous.y;
				maxJump = b3MaxFloat( maxJump, sqrtf( jumpX * jumpX + jumpY * jumpY ) );
				quadrants |= 1 << ( ( tilt.x >= 0.0f ? 0 : 1 ) + ( tilt.y >= 0.0f ? 0 : 2 ) );
			}
			previous = tilt;
		}

		ENSURE( quadrants == 15 );
		ENSURE( maxDeviation < 0.05f );

		// The boundary is about 6.5 radians around and one turn takes 1440 steps
		ENSURE( maxJump < 0.05f );
		ENSURE( b3Length( b3Body_GetAngularVelocity( f.bodyId ) ) < 5.0f );

		b3DestroyWorld( f.worldId );
	}

	// Live change: the limit the joint rests on is lowered and raised; changing another limit does not move it
	{
		JointFixture f = CreateJointFixture();

		b3SphericalJointDef def = b3DefaultSphericalJointDef();
		SetCommonFrames( &def.base, &f );
		def.enableConeLimit = true;
		def.enableEllipticalCone = true;
		def.enableAsymmetricCone = true;
		def.coneAngleX = 1.2f;
		def.coneAngleNegativeX = 0.5f;
		def.coneAngleY = 0.8f;
		def.coneAngleNegativeY = 0.6f;
		def.enableMotor = true;
		def.motorVelocity = (b3Vec3){ 0.0f, 2.0f, 0.0f };
		def.maxMotorTorque = 2.0f;
		b3JointId jointId = b3CreateSphericalJoint( f.worldId, &def );

		// Changing a limit does not wake the body, like the other joint limits
		b3Body_EnableSleep( f.bodyId, false );

		float targets[] = { 1.2f, 0.6f, 0.6f, 1.0f };
		float negativeX[] = { 0.5f, 0.5f, 0.3f, 0.3f };
		for ( int phase = 0; phase < 4; ++phase )
		{
			b3SphericalJoint_SetAsymmetricConeLimits( jointId, targets[phase], negativeX[phase], 0.8f, 0.6f );
			float maxSpeed = 0.0f;
			for ( int step = 0; step < 180; ++step )
			{
				b3World_Step( f.worldId, 1.0f / 60.0f, 4 );
				maxSpeed = b3MaxFloat( maxSpeed, b3Length( b3Body_GetAngularVelocity( f.bodyId ) ) );
			}

			b3Vec2 tilt = b3SphericalJoint_GetConeAngles( jointId );
			ENSURE_SMALL( tilt.x - targets[phase], 0.02f );
			ENSURE_SMALL( tilt.y, 0.02f );
			ENSURE( maxSpeed < 10.0f );
		}

		b3DestroyWorld( f.worldId );
	}

	// The rest pose is inside the cone: an undriven joint stays at tilt 0
	{
		JointFixture f = CreateJointFixture();

		b3SphericalJointDef def = b3DefaultSphericalJointDef();
		SetCommonFrames( &def.base, &f );
		def.enableConeLimit = true;
		def.enableEllipticalCone = true;
		def.enableAsymmetricCone = true;
		def.coneAngleX = limits[0];
		def.coneAngleNegativeX = limits[1];
		def.coneAngleY = limits[2];
		def.coneAngleNegativeY = limits[3];
		b3JointId jointId = b3CreateSphericalJoint( f.worldId, &def );

		for ( int step = 0; step < 60; ++step )
		{
			b3World_Step( f.worldId, 1.0f / 60.0f, 4 );
		}

		b3Vec2 tilt = b3SphericalJoint_GetConeAngles( jointId );
		ENSURE( tilt.x == 0.0f && tilt.y == 0.0f );
		ENSURE( b3Length( b3Joint_GetConstraintTorque( jointId ) ) == 0.0f );

		b3DestroyWorld( f.worldId );
	}

	// Symmetric pairs step exactly like the elliptical cone
	b3WorldTransform transforms[2];
	for ( int asymmetric = 0; asymmetric < 2; ++asymmetric )
	{
		JointFixture f = CreateJointFixture();

		b3SphericalJointDef def = b3DefaultSphericalJointDef();
		SetCommonFrames( &def.base, &f );
		def.enableConeLimit = true;
		def.enableEllipticalCone = true;
		def.enableAsymmetricCone = asymmetric == 1;
		def.coneAngleX = 0.5f;
		def.coneAngleY = 1.1f;
		def.coneAngleNegativeX = 0.5f;
		def.coneAngleNegativeY = 1.1f;
		def.enableTwistLimit = true;
		def.lowerTwistAngle = -0.3f;
		def.upperTwistAngle = 0.4f;
		def.enableMotor = true;
		def.motorVelocity = (b3Vec3){ -1.0f, 2.0f, 0.5f };
		def.maxMotorTorque = 2.0f;
		b3JointId jointId = b3CreateSphericalJoint( f.worldId, &def );

		for ( int step = 0; step < 240; ++step )
		{
			if ( step == 120 )
			{
				b3SphericalJoint_SetMotorVelocity( jointId, (b3Vec3){ 2.0f, -1.0f, -0.5f } );
			}
			b3World_Step( f.worldId, 1.0f / 60.0f, 4 );
		}

		transforms[asymmetric] = b3Body_GetTransform( f.bodyId );
		b3DestroyWorld( f.worldId );
	}

	ENSURE( transforms[0].p.x == transforms[1].p.x && transforms[0].p.y == transforms[1].p.y &&
			transforms[0].p.z == transforms[1].p.z );
	ENSURE( transforms[0].q.v.x == transforms[1].q.v.x && transforms[0].q.v.y == transforms[1].q.v.y &&
			transforms[0].q.v.z == transforms[1].q.v.z && transforms[0].q.s == transforms[1].q.s );

	return 0;
}

static int TestWeldJoint( void )
{
	JointFixture f = CreateJointFixture();

	b3WeldJointDef def = b3DefaultWeldJointDef();
	SetCommonFrames( &def.base, &f );
	b3JointId jointId = b3CreateWeldJoint( f.worldId, &def );

	if ( ExerciseJointBase( jointId, f.worldId, f.groundId, f.bodyId, b3_weldJoint ) != 0 )
	{
		return 1;
	}

	b3WeldJoint_SetLinearHertz( jointId, 3.0f );
	ENSURE( b3WeldJoint_GetLinearHertz( jointId ) == 3.0f );

	b3WeldJoint_SetLinearDampingRatio( jointId, 0.5f );
	ENSURE( b3WeldJoint_GetLinearDampingRatio( jointId ) == 0.5f );

	b3WeldJoint_SetAngularHertz( jointId, 4.0f );
	ENSURE( b3WeldJoint_GetAngularHertz( jointId ) == 4.0f );

	b3WeldJoint_SetAngularDampingRatio( jointId, 0.7f );
	ENSURE( b3WeldJoint_GetAngularDampingRatio( jointId ) == 0.7f );

	return FinishJoint( jointId, f.worldId );
}

static int TestWheelJoint( void )
{
	JointFixture f = CreateJointFixture();

	b3WheelJointDef def = b3DefaultWheelJointDef();
	SetCommonFrames( &def.base, &f );
	b3JointId jointId = b3CreateWheelJoint( f.worldId, &def );

	if ( ExerciseJointBase( jointId, f.worldId, f.groundId, f.bodyId, b3_wheelJoint ) != 0 )
	{
		return 1;
	}

	b3WheelJoint_EnableSuspension( jointId, true );
	ENSURE( b3WheelJoint_IsSuspensionEnabled( jointId ) == true );

	b3WheelJoint_SetSuspensionHertz( jointId, 5.0f );
	ENSURE( b3WheelJoint_GetSuspensionHertz( jointId ) == 5.0f );

	b3WheelJoint_SetSuspensionDampingRatio( jointId, 0.5f );
	ENSURE( b3WheelJoint_GetSuspensionDampingRatio( jointId ) == 0.5f );

	b3WheelJoint_EnableSuspensionLimit( jointId, true );
	ENSURE( b3WheelJoint_IsSuspensionLimitEnabled( jointId ) == true );

	b3WheelJoint_SetSuspensionLimits( jointId, -1.0f, 1.0f );
	ENSURE( b3WheelJoint_GetLowerSuspensionLimit( jointId ) == -1.0f );
	ENSURE( b3WheelJoint_GetUpperSuspensionLimit( jointId ) == 1.0f );

	b3WheelJoint_EnableSpinMotor( jointId, true );
	ENSURE( b3WheelJoint_IsSpinMotorEnabled( jointId ) == true );

	b3WheelJoint_SetSpinMotorSpeed( jointId, 6.0f );
	ENSURE( b3WheelJoint_GetSpinMotorSpeed( jointId ) == 6.0f );

	b3WheelJoint_SetMaxSpinTorque( jointId, 35.0f );
	ENSURE( b3WheelJoint_GetMaxSpinTorque( jointId ) == 35.0f );

	float spinSpeed = b3WheelJoint_GetSpinSpeed( jointId );
	float spinTorque = b3WheelJoint_GetSpinTorque( jointId );
	MAYBE_UNUSED( spinSpeed );
	MAYBE_UNUSED( spinTorque );

	b3WheelJoint_EnableSteering( jointId, true );
	ENSURE( b3WheelJoint_IsSteeringEnabled( jointId ) == true );

	b3WheelJoint_SetSteeringHertz( jointId, 7.0f );
	ENSURE( b3WheelJoint_GetSteeringHertz( jointId ) == 7.0f );

	b3WheelJoint_SetSteeringDampingRatio( jointId, 0.8f );
	ENSURE( b3WheelJoint_GetSteeringDampingRatio( jointId ) == 0.8f );

	b3WheelJoint_SetMaxSteeringTorque( jointId, 45.0f );
	ENSURE( b3WheelJoint_GetMaxSteeringTorque( jointId ) == 45.0f );

	b3WheelJoint_EnableSteeringLimit( jointId, true );
	ENSURE( b3WheelJoint_IsSteeringLimitEnabled( jointId ) == true );

	b3WheelJoint_SetSteeringLimits( jointId, -0.6f, 0.6f );
	ENSURE( b3WheelJoint_GetLowerSteeringLimit( jointId ) == -0.6f );
	ENSURE( b3WheelJoint_GetUpperSteeringLimit( jointId ) == 0.6f );

	b3WheelJoint_SetTargetSteeringAngle( jointId, 0.25f );
	ENSURE( b3WheelJoint_GetTargetSteeringAngle( jointId ) == 0.25f );

	float steeringAngle = b3WheelJoint_GetSteeringAngle( jointId );
	float steeringTorque = b3WheelJoint_GetSteeringTorque( jointId );
	MAYBE_UNUSED( steeringAngle );
	MAYBE_UNUSED( steeringTorque );

	return FinishJoint( jointId, f.worldId );
}

// Issue #117: a joint created with collideConnected false must clear contacts
// that already exist between the two bodies.
static int TestCreateJointClearsContacts( void )
{
	b3WorldDef worldDef = b3DefaultWorldDef();
	worldDef.gravity = b3Vec3_zero;
	b3WorldId worldId = b3CreateWorld( &worldDef );

	b3BodyDef bodyDef = b3DefaultBodyDef();
	bodyDef.type = b3_dynamicBody;

	bodyDef.position = (b3Pos){ 0.0f, 0.0f, 0.0f };
	b3BodyId bodyIdA = b3CreateBody( worldId, &bodyDef );

	// Overlapping so a touching contact forms
	bodyDef.position = (b3Pos){ 0.5f, 0.0f, 0.0f };
	b3BodyId bodyIdB = b3CreateBody( worldId, &bodyDef );

	b3ShapeDef shapeDef = b3DefaultShapeDef();
	shapeDef.density = 1.0f;
	b3BoxHull box = b3MakeBoxHull( 0.5f, 0.5f, 0.5f );
	b3CreateHullShape( bodyIdA, &shapeDef, &box.base );
	b3CreateHullShape( bodyIdB, &shapeDef, &box.base );

	b3World_Step( worldId, 1.0f / 60.0f, 4 );
	ENSURE( b3Body_GetContactCapacity( bodyIdA ) > 0 );

	b3RevoluteJointDef jointDef = b3DefaultRevoluteJointDef();
	jointDef.base.bodyIdA = bodyIdA;
	jointDef.base.bodyIdB = bodyIdB;
	jointDef.base.collideConnected = false;
	b3CreateRevoluteJoint( worldId, &jointDef );

	ENSURE( b3Body_GetContactCapacity( bodyIdA ) == 0 );
	ENSURE( b3Body_GetContactCapacity( bodyIdB ) == 0 );

	b3World_Step( worldId, 1.0f / 60.0f, 4 );
	ENSURE( b3Body_GetContactCapacity( bodyIdA ) == 0 );

	b3DestroyWorld( worldId );
	return 0;
}

// Issue #164: a joint with no dynamic body lives in the static set even when one body is an awake
// kinematic. Disabling and enabling that body has to respect this, whether the joint was created
// that way or got there through body type changes.
static int TestNonDynamicJointDisable( void )
{
	b3WorldDef worldDef = b3DefaultWorldDef();
	worldDef.gravity = b3Vec3_zero;
	b3WorldId worldId = b3CreateWorld( &worldDef );

	b3BodyDef bodyDef = b3DefaultBodyDef();
	bodyDef.type = b3_dynamicBody;
	b3BodyId bodyIdA = b3CreateBody( worldId, &bodyDef );
	bodyDef.position = (b3Pos){ 2.0f, 0.0f, 0.0f };
	b3BodyId bodyIdB = b3CreateBody( worldId, &bodyDef );

	b3ShapeDef shapeDef = b3DefaultShapeDef();
	b3BoxHull box = b3MakeCubeHull( 0.5f );
	b3CreateHullShape( bodyIdA, &shapeDef, &box.base );
	b3CreateHullShape( bodyIdB, &shapeDef, &box.base );

	b3WeldJointDef jointDef = b3DefaultWeldJointDef();
	jointDef.base.bodyIdA = bodyIdA;
	jointDef.base.bodyIdB = bodyIdB;
	b3JointId weldId = b3CreateWeldJoint( worldId, &jointDef );

	b3Body_SetType( bodyIdA, b3_staticBody );
	b3Body_SetType( bodyIdB, b3_kinematicBody );
	b3World_Step( worldId, 1.0f / 60.0f, 4 );

	b3Body_Disable( bodyIdB );
	b3World_Step( worldId, 1.0f / 60.0f, 4 );
	b3Body_Enable( bodyIdB );
	b3World_Step( worldId, 1.0f / 60.0f, 4 );
	ENSURE( b3Joint_IsValid( weldId ) );

	b3Body_SetType( bodyIdB, b3_dynamicBody );
	b3World_Step( worldId, 1.0f / 60.0f, 4 );
	ENSURE( b3Joint_IsAwake( weldId ) );

	// Created directly between a static and a kinematic body
	bodyDef.type = b3_kinematicBody;
	bodyDef.position = (b3Pos){ 4.0f, 0.0f, 0.0f };
	b3BodyId bodyIdC = b3CreateBody( worldId, &bodyDef );
	b3CreateHullShape( bodyIdC, &shapeDef, &box.base );

	b3RevoluteJointDef revoluteDef = b3DefaultRevoluteJointDef();
	revoluteDef.base.bodyIdA = bodyIdA;
	revoluteDef.base.bodyIdB = bodyIdC;
	b3JointId revoluteId = b3CreateRevoluteJoint( worldId, &revoluteDef );

	b3Body_Disable( bodyIdC );
	b3Body_Enable( bodyIdC );
	b3World_Step( worldId, 1.0f / 60.0f, 4 );
	ENSURE( b3Joint_IsAwake( revoluteId ) == false );

	b3DestroyWorld( worldId );
	return 0;
}

int JointTest( void )
{
	RUN_SUBTEST( TestParallelJoint );
	RUN_SUBTEST( TestDistanceJoint );
	RUN_SUBTEST( TestFilterJoint );
	RUN_SUBTEST( TestMotorJoint );
	RUN_SUBTEST( TestPrismaticJoint );
	RUN_SUBTEST( TestRevoluteJoint );
	RUN_SUBTEST( TestSphericalJoint );
	RUN_SUBTEST( TestWeldJoint );
	RUN_SUBTEST( TestWheelJoint );
	RUN_SUBTEST( TestCreateJointClearsContacts );
	RUN_SUBTEST( TestNonDynamicJointDisable );
	RUN_SUBTEST( TestArmatureAcceleration );
	RUN_SUBTEST( TestArmatureEnergy );
	RUN_SUBTEST( TestEllipticalConeJacobian );
	RUN_SUBTEST( TestEllipticalConeLimit );
	RUN_SUBTEST( TestAsymmetricConeJacobian );
	RUN_SUBTEST( TestAsymmetricConeLimit );

	return 0;
}

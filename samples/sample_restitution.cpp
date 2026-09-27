// SPDX-FileCopyrightText: 2026 Erin Catto
// SPDX-License-Identifier: MIT

#include "gfx/debug_adapter.h"
#include "gfx/draw.h"
#include "imgui.h"
#include "sample.h"

#include "box3d/box3d.h"

#include <stdio.h>

// Restitution is approximate since Box3D uses speculative collision
class VaryingRestitution : public Sample
{
public:
	enum ShapeType
	{
		e_sphereShape = 0,
		e_boxShape
	};

	explicit VaryingRestitution( SampleContext* context )
		: Sample( context )
	{
		if ( context->restart == false )
		{
			m_camera->SetView( 0.0f, 25.0f, 85.0f, { 0.0f, 20.0f, 0.0f } );
		}

		AddGroundBox( 50.0f );

		m_shapeType = e_sphereShape;

		CreateBodies();
	}

	void CreateBodies()
	{
		for ( int i = 0; i < m_count; ++i )
		{
			if ( B3_IS_NON_NULL( m_bodyIds[i] ) )
			{
				b3DestroyBody( m_bodyIds[i] );
				m_bodyIds[i] = b3_nullBodyId;
			}
		}

		b3Sphere sphere = { b3Vec3_zero, 0.5f };
		b3BoxHull box = b3MakeCubeHull( 0.5f );

		b3ShapeDef shapeDef = b3DefaultShapeDef();
		shapeDef.density = 1.0f;
		shapeDef.baseMaterial.restitution = 0.0f;
		shapeDef.baseMaterial.friction = 0.0f;

		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.type = b3_dynamicBody;

		float dr = 1.0f / ( m_count > 1 ? m_count - 1 : 1 );
		float x = -1.0f * ( m_count - 1 );
		float dx = 2.0f;

		for ( int i = 0; i < m_count; ++i )
		{
			char buffer[32];
			snprintf( buffer, 32, "%.2f", shapeDef.baseMaterial.restitution );
			bodyDef.name = buffer;
			bodyDef.position = { x, 40.0f, 0.0f };
			b3BodyId bodyId = b3CreateBody( m_worldId, &bodyDef );

			m_bodyIds[i] = bodyId;

			if ( m_shapeType == e_sphereShape )
			{
				b3CreateSphereShape( bodyId, &shapeDef, &sphere );
			}
			else
			{
				b3CreateHullShape( bodyId, &shapeDef, &box.base );
			}

			shapeDef.baseMaterial.restitution += dr;
			x += dx;
		}
	}

	bool DrawControls() override
	{
		ImGui::PushItemWidth( 6.0f * ImGui::GetFontSize() );

		bool changed = false;
		const char* shapeTypes[] = { "Sphere", "Box" };

		int shapeType = int( m_shapeType );
		changed = changed || ImGui::Combo( "Shape", &shapeType, shapeTypes, IM_ARRAYSIZE( shapeTypes ) );
		m_shapeType = ShapeType( shapeType );

		ImGui::PopItemWidth();

		changed = changed || ImGui::Button( "Reset" );

		if ( changed )
		{
			CreateBodies();
		}

		return true;
	}

	void Step() override
	{
		Sample::Step();

		float h = 1.0f * m_count;
		DrawLine( { -h, 40.5f, 0.0f }, { h, 40.5f, 0.0f }, MakeColor( b3_colorRed ) );
	}

	static Sample* Create( SampleContext* context )
	{
		return new VaryingRestitution( context );
	}

	static constexpr int m_count = 40;

	b3BodyId m_bodyIds[m_count] = {};
	ShapeType m_shapeType;
};

static int sampleVaryingRestitution = RegisterSample( "Restitution", "Varying", VaryingRestitution::Create );

// Tests how a single bouncing box behaves.
class SingleBoxRestitution : public Sample
{
public:
	explicit SingleBoxRestitution( SampleContext* context )
		: Sample( context )
	{
		if ( context->restart == false )
		{
			m_camera->SetView( 20.0f, 10.0f, 16.0f, { 0.0f, 3.0f, 0.0f } );
		}

		AddGroundBox( 4.0f );

		m_height = 5.0f;
		m_maxY = 5.0f;

		b3BoxHull box = b3MakeCubeHull( 0.5f );

		b3ShapeDef shapeDef = b3DefaultShapeDef();
		shapeDef.density = 1.0f;
		shapeDef.baseMaterial.restitution = 1.0f;
		shapeDef.baseMaterial.friction = 0.0f;
		shapeDef.enableHitEvents = true;

		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.type = b3_dynamicBody;
		bodyDef.position = { 0.0f, m_height, 0.0f };
		bodyDef.safetyFactor = 0.01f;
		m_bodyId = b3CreateBody( m_worldId, &bodyDef );
		b3CreateHullShape( m_bodyId, &shapeDef, &box.base );

		m_startEnergy = MeasureEnergy( m_worldId, &m_bodyId, 1 ).Total();
		m_peakEnergy = m_startEnergy;
	}

	void Step() override
	{
		Sample::Step();

		DrawLine( { -4.0f, m_height + 0.5f, 0.0f }, { 4.0f, m_height + 0.5f, 0.0f }, MakeColor( b3_colorRed ) );

		b3ContactEvents events = b3World_GetContactEvents( m_worldId );

		b3Pos p = b3Body_GetPosition( m_bodyId );
		if ( events.hitCount == 1 )
		{
			m_maxY = (float)p.y;
		}
		else
		{
			m_maxY = b3MaxFloat( m_maxY, (float)p.y );
		}

		DrawTextLine( "maxY = %.2f", m_maxY );

		MechanicalEnergy energy = MeasureEnergy( m_worldId, &m_bodyId, 1 );
		float total = energy.Total();
		m_peakEnergy = b3MaxFloat( m_peakEnergy, total );

		float scale = m_startEnergy != 0.0f ? 100.0f / m_startEnergy : 0.0f;
		DrawTextLine( "kinetic   = %.3f J linear + %.3f J angular", energy.linear, energy.angular );
		DrawTextLine( "potential = %.3f J", energy.potential );
		DrawTextLine( "total     = %.3f J (%.2f%% of start, peak %.2f%%)", total, scale * total, scale * m_peakEnergy );
	}

	static Sample* Create( SampleContext* context )
	{
		return new SingleBoxRestitution( context );
	}

	b3BodyId m_bodyId;
	float m_maxY;
	float m_startEnergy = 0.0f;
	float m_peakEnergy = 0.0f;
	float m_height;
};

static int sampleSingleBoxRestitution = RegisterSample( "Restitution", "Single Box Restitution", SingleBoxRestitution::Create );

class SingleSphereRestitution : public Sample
{
public:
	explicit SingleSphereRestitution( SampleContext* context )
		: Sample( context )
	{
		if ( context->restart == false )
		{
			m_camera->SetView( 20.0f, 10.0f, 24.0f, { 0.0f, 5.0f, 0.0f } );
		}

		AddGroundBox( 4.0f );

		b3Sphere sphere = { b3Vec3_zero, 0.5f };

		b3ShapeDef shapeDef = b3DefaultShapeDef();
		shapeDef.density = 1.0f;
		shapeDef.baseMaterial.restitution = 1.0f;
		shapeDef.baseMaterial.friction = 0.0f;
		shapeDef.enableHitEvents = true;

		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.type = b3_dynamicBody;
		bodyDef.position = { 0.0f, 10.0f, 0.0f };
		bodyDef.safetyFactor = 0.01f;
		m_bodyId = b3CreateBody( m_worldId, &bodyDef );
		b3CreateSphereShape( m_bodyId, &shapeDef, &sphere );

		m_maxY = (float)bodyDef.position.y;

		m_startEnergy = MeasureEnergy( m_worldId, &m_bodyId, 1 ).Total();
		m_peakEnergy = m_startEnergy;
	}

	void Step() override
	{
		Sample::Step();

		b3ContactEvents events = b3World_GetContactEvents( m_worldId );

		b3Pos p = b3Body_GetPosition( m_bodyId );
		if ( events.hitCount == 1 )
		{
			m_maxY = (float)p.y;
		}
		else
		{
			m_maxY = b3MaxFloat( m_maxY, (float)p.y );
		}

		DrawLine( { -4.0f, 10.5f, 0.0f }, { 4.0f, 10.5f, 0.0f }, MakeColor( b3_colorRed ) );

		DrawTextLine( "maxY = %.2f", m_maxY );

		MechanicalEnergy energy = MeasureEnergy( m_worldId, &m_bodyId, 1 );
		float total = energy.Total();
		m_peakEnergy = b3MaxFloat( m_peakEnergy, total );

		float scale = m_startEnergy != 0.0f ? 100.0f / m_startEnergy : 0.0f;
		DrawTextLine( "kinetic   = %.3f J linear + %.3f J angular", energy.linear, energy.angular );
		DrawTextLine( "potential = %.3f J", energy.potential );
		DrawTextLine( "total     = %.3f J (%.2f%% of start, peak %.2f%%)", total, scale * total, scale * m_peakEnergy );
	}

	static Sample* Create( SampleContext* context )
	{
		return new SingleSphereRestitution( context );
	}

	b3BodyId m_bodyId;
	float m_maxY;
	float m_startEnergy = 0.0f;
	float m_peakEnergy = 0.0f;
};

static int sampleSingleSphereRestitution =
	RegisterSample( "Restitution", "Single Sphere Restitution", SingleSphereRestitution::Create );

// Similar to the MeasureSupportedBounce unit test
class SphereStackRestitution : public Sample
{
public:
	static constexpr float m_impactSpeed = 5.0f;
	static constexpr int m_maxStackCount = 3;

	explicit SphereStackRestitution( SampleContext* context )
		: Sample( context )
	{
		if ( context->restart == false )
		{
			m_camera->SetView( 20.0f, 10.0f, 12.0f, { 0.0f, 2.5f, 0.0f } );
		}

		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.position = { 0.0f, -1.0f, 0.0f };
		b3BodyId groundId = b3CreateBody( m_worldId, &bodyDef );

		b3ShapeDef shapeDef = b3DefaultShapeDef();
		shapeDef.baseMaterial.friction = 0.0f;
		shapeDef.baseMaterial.restitution = 0.0f;
		b3BoxHull box = b3MakeBoxHull( 40.0f, 1.0f, 40.0f );
		b3ShapeId groundShapeId = b3CreateHullShape( groundId, &shapeDef, &box.base );
		SetGroundShape( groundShapeId );

		CreateScene();
	}

	b3BodyId CreateBall( float y, float velocityY, float restitution, bool hitEvents )
	{
		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.type = b3_dynamicBody;
		bodyDef.position = { 0.0f, y, 0.0f };
		bodyDef.linearVelocity = { 0.0f, velocityY, 0.0f };
		bodyDef.enableSleep = false;
		b3BodyId bodyId = b3CreateBody( m_worldId, &bodyDef );

		b3ShapeDef shapeDef = b3DefaultShapeDef();
		shapeDef.baseMaterial.friction = 0.0f;
		shapeDef.baseMaterial.restitution = restitution;
		shapeDef.enableHitEvents = hitEvents;
		b3Sphere sphere = { b3Vec3_zero, 0.5f };
		b3CreateSphereShape( bodyId, &shapeDef, &sphere );

		return bodyId;
	}

	void CreateScene()
	{
		for ( int i = 0; i < m_bodyCount; ++i )
		{
			b3DestroyBody( m_bodyIds[i] );
		}
		m_bodyCount = 0;

		if ( m_gravity )
		{
			b3World_SetGravity( m_worldId, { 0.0f, -10.0f, 0.0f } );
		}
		else
		{
			b3World_SetGravity( m_worldId, b3Vec3_zero );
		}

		for ( int i = 0; i < m_stackCount; ++i )
		{
			m_bodyIds[m_bodyCount] = CreateBall( 0.5f + 1.0f * i, 0.0f, 0.0f, false );
			m_bodyCount += 1;
		}

		// Start half a step of travel above contact so the impact lands mid step, matching the test
		m_startHeight = 0.5f + 1.0f * m_stackCount + 0.5f * m_impactSpeed * ( 1.0f / 60.0f );

		m_impactorId = CreateBall( m_startHeight, -m_impactSpeed, m_restitution, true );
		m_bodyIds[m_bodyCount] = m_impactorId;
		m_bodyCount += 1;

		m_startEnergy = MeasureEnergy( m_worldId, m_bodyIds, m_bodyCount ).Total();
		m_peakEnergy = m_startEnergy;

		m_coefficient = 0.0f;
		m_latched = false;
		m_hit = false;
	}

	bool DrawControls() override
	{
		bool rebuild = false;

		ImGui::PushItemWidth( 6.0f * ImGui::GetFontSize() );

		if ( ImGui::SliderFloat( "Restitution", &m_restitution, 0.0f, 1.0f, "%.2f" ) )
		{
			rebuild = true;
		}

		if ( ImGui::SliderInt( "Stack", &m_stackCount, 0, m_maxStackCount ) )
		{
			rebuild = true;
		}

		ImGui::PopItemWidth();

		if ( ImGui::Checkbox( "Gravity", &m_gravity ) )
		{
			rebuild = true;
		}

		if ( ImGui::Button( "Reset" ) )
		{
			rebuild = true;
		}

		if ( rebuild )
		{
			CreateScene();
		}

		return true;
	}

	void Step() override
	{
		Sample::Step();

		b3ContactEvents events = b3World_GetContactEvents( m_worldId );
		if ( events.hitCount > 0 )
		{
			m_hit = true;
		}

		float vy = b3Body_GetLinearVelocity( m_impactorId ).y;

		// The rebound only means something once the impact has happened and the impactor is leaving
		if ( m_latched == false && m_hit && vy > 0.0f )
		{
			m_coefficient = vy / m_impactSpeed;
			m_latched = true;
		}

		float supportSpeed = 0.0f;
		for ( int i = 0; i < m_stackCount; ++i )
		{
			supportSpeed = b3MaxFloat( supportSpeed, b3Length( b3Body_GetLinearVelocity( m_bodyIds[i] ) ) );
		}

		DrawLine( { -2.0f, m_startHeight, 0.0f }, { 2.0f, m_startHeight, 0.0f }, MakeColor( b3_colorRed ) );

		MechanicalEnergy energy = MeasureEnergy( m_worldId, m_bodyIds, m_bodyCount );
		float total = energy.Total();
		m_peakEnergy = b3MaxFloat( m_peakEnergy, total );

		DrawTextLine( "impactor vy = %.3f m/s", vy );

		DrawTextLine( "coefficient = %.4f live (target %.2f)", vy / m_impactSpeed, m_restitution );

		if ( m_latched )
		{
			DrawTextLine( "coefficient = %.4f at first rebound", m_coefficient );
		}

		DrawTextLine( "support speed = %.4f m/s", supportSpeed );

		float scale = m_startEnergy != 0.0f ? 100.0f / m_startEnergy : 0.0f;
		DrawTextLine( "kinetic   = %.3f J linear + %.3f J angular", energy.linear, energy.angular );
		DrawTextLine( "potential = %.3f J", energy.potential );
		DrawTextLine( "total     = %.3f J (%.2f%% of start, peak %.2f%%)", total, scale * total, scale * m_peakEnergy );
	}

	static Sample* Create( SampleContext* context )
	{
		return new SphereStackRestitution( context );
	}

	b3BodyId m_bodyIds[m_maxStackCount + 1] = {};
	b3BodyId m_impactorId = b3_nullBodyId;
	int m_bodyCount = 0;
	int m_stackCount = 2;
	float m_restitution = 1.0f;
	float m_startHeight = 0.0f;
	float m_coefficient = 0.0f;
	float m_startEnergy = 0.0f;
	float m_peakEnergy = 0.0f;
	bool m_gravity = false;
	bool m_latched = false;
	bool m_hit = false;
};

static int sampleSphereStackRestitution = RegisterSample( "Restitution", "Sphere Stack Restitution", SphereStackRestitution::Create );

class RestitutionPropagation : public Sample
{
public:
	static constexpr int m_columnCount = 3;
	static constexpr float m_dropHeight = 5.0f;

	explicit RestitutionPropagation( SampleContext* context )
		: Sample( context )
	{
		if ( context->restart == false )
		{
			m_camera->SetView( 0.0f, 10.0f, 24.0f, { 0.0f, 4.0f, 0.0f } );
		}

		AddGroundBox( 40.0f );

		CreateScene();
	}

	void CreateScene()
	{
		for ( int i = 0; i < m_bodyCount; ++i )
		{
			b3DestroyBody( m_bodyIds[i] );
		}
		m_bodyCount = 0;
		m_crateCount = 0;
		m_kick = 0.0f;

		b3BoxHull box = b3MakeCubeHull( 0.5f );
		b3Sphere sphere = { b3Vec3_zero, 0.5f };

		for ( int column = 0; column < m_columnCount; ++column )
		{
			float x = 4.0f * ( column - 1 );

			for ( int k = 0; k < column; ++k )
			{
				b3BodyDef bodyDef = b3DefaultBodyDef();
				bodyDef.type = b3_dynamicBody;
				bodyDef.position = { x, 0.5f + 1.0f * k, 0.0f };
				bodyDef.enableSleep = false;
				b3BodyId crateId = b3CreateBody( m_worldId, &bodyDef );

				b3ShapeDef shapeDef = b3DefaultShapeDef();
				b3CreateHullShape( crateId, &shapeDef, &box.base );

				m_bodyIds[m_bodyCount++] = crateId;
				m_crateIds[m_crateCount++] = crateId;
			}

			m_restHeight[column] = 0.5f + 1.0f * column;

			b3BodyDef bodyDef = b3DefaultBodyDef();
			bodyDef.type = b3_dynamicBody;
			bodyDef.position = { x, m_restHeight[column] + m_dropHeight, 0.0f };
			bodyDef.enableSleep = false;
			b3BodyId ballId = b3CreateBody( m_worldId, &bodyDef );

			b3ShapeDef shapeDef = b3DefaultShapeDef();
			shapeDef.baseMaterial.restitution = m_restitution;
			b3CreateSphereShape( ballId, &shapeDef, &sphere );

			m_bodyIds[m_bodyCount++] = ballId;
			m_ballIds[column] = ballId;
			m_apex[column] = 0.0f;
			m_rebounding[column] = false;
			m_done[column] = false;
		}
	}

	bool DrawControls() override
	{
		ImGui::PushItemWidth( 6.0f * ImGui::GetFontSize() );
		bool rebuild = ImGui::SliderFloat( "Restitution", &m_restitution, 0.0f, 1.0f, "%.2f" );
		ImGui::PopItemWidth();

		if ( ImGui::Button( "Reset" ) )
		{
			rebuild = true;
		}

		if ( rebuild )
		{
			CreateScene();
		}

		return true;
	}

	void Step() override
	{
		Sample::Step();

		static const char* labels[m_columnCount] = { "ground", "one crate", "two crates" };

		for ( int column = 0; column < m_columnCount; ++column )
		{
			b3Vec3 v = b3Body_GetLinearVelocity( m_ballIds[column] );
			float height = float( b3Body_GetPosition( m_ballIds[column] ).y ) - m_restHeight[column];

			// The ball starts at rest and falls, so upward velocity means it bounced
			if ( m_rebounding[column] == false && v.y > 0.0f )
			{
				m_rebounding[column] = true;
			}

			if ( m_rebounding[column] && m_done[column] == false )
			{
				m_apex[column] = b3MaxFloat( m_apex[column], height );
				if ( v.y < 0.0f )
				{
					m_done[column] = true;
				}
			}

			float x = 4.0f * ( column - 1 );
			float dropY = m_restHeight[column] + m_dropHeight;
			DrawLine( { x - 1.0f, dropY, 0.0f }, { x + 1.0f, dropY, 0.0f }, MakeColor( b3_colorRed ) );
			if ( m_apex[column] > 0.0f )
			{
				float apexY = m_restHeight[column] + m_apex[column];
				DrawLine( { x - 1.0f, apexY, 0.0f }, { x + 1.0f, apexY, 0.0f }, MakeColor( b3_colorGreen ) );
			}

			DrawTextLine( "%s: apex %.2f m (%.0f%% of drop)", labels[column], m_apex[column],
						  100.0f * m_apex[column] / m_dropHeight );
		}

		for ( int i = 0; i < m_crateCount; ++i )
		{
			m_kick = b3MaxFloat( m_kick, b3Length( b3Body_GetLinearVelocity( m_crateIds[i] ) ) );
		}

		DrawTextLine( "peak crate speed %.2f m/s", m_kick );
	}

	static Sample* Create( SampleContext* context )
	{
		return new RestitutionPropagation( context );
	}

	b3BodyId m_bodyIds[2 * m_columnCount] = {};
	b3BodyId m_ballIds[m_columnCount] = {};
	b3BodyId m_crateIds[m_columnCount] = {};
	float m_restHeight[m_columnCount] = {};
	float m_apex[m_columnCount] = {};
	bool m_rebounding[m_columnCount] = {};
	bool m_done[m_columnCount] = {};
	int m_bodyCount = 0;
	int m_crateCount = 0;
	float m_restitution = 0.9f;
	float m_kick = 0.0f;
};

static int sampleRestitutionPropagation = RegisterSample( "Restitution", "Restitution Propagation", RestitutionPropagation::Create );

// Similar to the MeasureFlatBounce and SpinTest unit tests
class BoxRestitution : public Sample
{
public:
	static constexpr float m_impactSpeed = 5.0f;

	explicit BoxRestitution( SampleContext* context )
		: Sample( context )
	{
		if ( context->restart == false )
		{
			m_camera->SetView( 20.0f, 10.0f, 14.0f, { 0.0f, 3.0f, 0.0f } );
		}

		// Gravity would bias the measured coefficient
		b3World_SetGravity( m_worldId, b3Vec3_zero );

		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.position = { 0.0f, -1.0f, 0.0f };
		b3BodyId groundId = b3CreateBody( m_worldId, &bodyDef );

		b3ShapeDef shapeDef = b3DefaultShapeDef();
		shapeDef.baseMaterial.friction = 0.0f;
		shapeDef.baseMaterial.restitution = 0.0f;
		b3BoxHull box = b3MakeBoxHull( 40.0f, 1.0f, 40.0f );
		b3ShapeId groundShapeId = b3CreateHullShape( groundId, &shapeDef, &box.base );
		SetGroundShape( groundShapeId );

		CreateScene();
	}

	void CreateScene()
	{
		if ( B3_IS_NON_NULL( m_boxId ) )
		{
			b3DestroyBody( m_boxId );
		}

		// Start half a step of travel above contact so the impact lands mid step, matching the test
		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.type = b3_dynamicBody;
		bodyDef.position = { 0.0f, 0.25f + 0.5f * m_impactSpeed * ( 1.0f / 60.0f ), 0.0f };
		bodyDef.linearVelocity = { 0.0f, -m_impactSpeed, 0.0f };
		bodyDef.angularVelocity = { 0.0f, 0.0f, m_spin };
		bodyDef.enableSleep = false;
		m_boxId = b3CreateBody( m_worldId, &bodyDef );

		b3ShapeDef shapeDef = b3DefaultShapeDef();
		shapeDef.density = 1.0f;
		shapeDef.baseMaterial.friction = 0.0f;
		shapeDef.baseMaterial.restitution = m_restitution;
		shapeDef.enableHitEvents = true;
		b3BoxHull box = b3MakeBoxHull( 1.0f, 0.25f, 1.0f );
		b3CreateHullShape( m_boxId, &shapeDef, &box.base );

		m_startEnergy = MeasureEnergy( m_worldId, &m_boxId, 1 ).Total();
		m_peakEnergy = m_startEnergy;

		m_coefficient = 0.0f;
		m_latched = false;
		m_hit = false;
	}

	bool DrawControls() override
	{
		bool rebuild = false;

		ImGui::PushItemWidth( 6.0f * ImGui::GetFontSize() );

		if ( ImGui::SliderFloat( "Restitution", &m_restitution, 0.0f, 1.0f, "%.2f" ) )
		{
			rebuild = true;
		}

		if ( ImGui::SliderFloat( "Spin", &m_spin, 0.0f, 2.0f, "%.2f" ) )
		{
			rebuild = true;
		}

		ImGui::PopItemWidth();

		if ( ImGui::Button( "Reset" ) )
		{
			rebuild = true;
		}

		if ( rebuild )
		{
			CreateScene();
		}

		return true;
	}

	void Step() override
	{
		Sample::Step();

		b3ContactEvents events = b3World_GetContactEvents( m_worldId );
		if ( events.hitCount > 0 )
		{
			m_hit = true;
		}

		float vy = b3Body_GetLinearVelocity( m_boxId ).y;
		b3Vec3 w = b3Body_GetAngularVelocity( m_boxId );

		if ( m_latched == false && m_hit && vy > 0.0f )
		{
			m_coefficient = vy / m_impactSpeed;
			m_latched = true;
		}

		Vec4 yellow = MakeColor( b3_colorYellow );
		DrawPoint( b3Body_GetWorldPoint( m_boxId, { -1.0f, -0.25f, -1.0f } ), 8.0f, yellow );
		DrawPoint( b3Body_GetWorldPoint( m_boxId, { 1.0f, -0.25f, -1.0f } ), 8.0f, yellow );
		DrawPoint( b3Body_GetWorldPoint( m_boxId, { -1.0f, -0.25f, 1.0f } ), 8.0f, yellow );
		DrawPoint( b3Body_GetWorldPoint( m_boxId, { 1.0f, -0.25f, 1.0f } ), 8.0f, yellow );

		MechanicalEnergy energy = MeasureEnergy( m_worldId, &m_boxId, 1 );
		float total = energy.Total();
		m_peakEnergy = b3MaxFloat( m_peakEnergy, total );

		DrawTextLine( "vy = %.3f m/s", vy );

		DrawTextLine( "coefficient = %.4f live (target %.2f)", vy / m_impactSpeed, m_restitution );

		if ( m_latched )
		{
			DrawTextLine( "coefficient = %.4f at first rebound", m_coefficient );
		}

		// The spin is about z, so any x or y component is residual from the sequential point solve
		DrawTextLine( "spin in = %.2f, spin out = %.4f (ideal %.2f at e = 1)", m_spin, w.z, -m_spin );
		DrawTextLine( "off axis spin = %.4f rad/s", sqrtf( w.x * w.x + w.y * w.y ) );

		float scale = m_startEnergy != 0.0f ? 100.0f / m_startEnergy : 0.0f;
		DrawTextLine( "kinetic   = %.3f J linear + %.3f J angular", energy.linear, energy.angular );
		DrawTextLine( "potential = %.3f J", energy.potential );
		DrawTextLine( "total     = %.3f J (%.2f%% of start, peak %.2f%%)", total, scale * total, scale * m_peakEnergy );
	}

	static Sample* Create( SampleContext* context )
	{
		return new BoxRestitution( context );
	}

	b3BodyId m_boxId = b3_nullBodyId;
	float m_restitution = 0.9f;
	float m_spin = 0.0f;
	float m_coefficient = 0.0f;
	float m_startEnergy = 0.0f;
	float m_peakEnergy = 0.0f;
	bool m_latched = false;
	bool m_hit = false;
};

static int sampleBoxRestitution = RegisterSample( "Restitution", "Box Restitution", BoxRestitution::Create );

class RotatedBoxRestitution : public Sample
{
public:
	static constexpr int m_count = 12;
	static constexpr float m_dropHeight = 10.0f;

	explicit RotatedBoxRestitution( SampleContext* context )
		: Sample( context )
	{
		if ( context->restart == false )
		{
			m_camera->SetView( 0.0f, 15.0f, 36.0f, { 0.0f, 5.0f, 0.0f } );
		}

		AddGroundBox( 2.0f * m_count + 1.0f );

		CreateScene();
	}

	void CreateScene()
	{
		for ( int i = 0; i < m_count; ++i )
		{
			if ( B3_IS_NON_NULL( m_bodyIds[i] ) )
			{
				b3DestroyBody( m_bodyIds[i] );
				m_bodyIds[i] = b3_nullBodyId;
			}
		}

		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.type = b3_dynamicBody;
		bodyDef.safetyFactor = m_safetyFactor;

		b3ShapeDef shapeDef = b3DefaultShapeDef();
		shapeDef.baseMaterial.friction = m_friction;
		shapeDef.baseMaterial.restitution = m_restitution;

		// Boxes in a negative group never collide with each other
		shapeDef.filter.groupIndex = -1;

		b3BoxHull box = b3MakeCubeHull( 0.5f );

		// A cube repeats every quarter turn
		float dq = 0.5f * B3_PI / m_count;
		float x = -1.0f * ( m_count - 1 );

		for ( int i = 0; i < m_count; ++i )
		{
			bodyDef.position = { x, m_dropHeight, 0.0f };
			bodyDef.rotation = b3MakeQuatFromAxisAngle( b3Vec3_axisZ, i * dq );
			m_bodyIds[i] = b3CreateBody( m_worldId, &bodyDef );
			b3CreateHullShape( m_bodyIds[i], &shapeDef, &box.base );

			m_startEnergy[i] = MeasureEnergy( m_worldId, &m_bodyIds[i], 1 ).Total();

			x += 2.0f;
		}
	}

	bool DrawControls() override
	{
		bool rebuild = false;

		ImGui::PushItemWidth( 6.0f * ImGui::GetFontSize() );

		if ( ImGui::SliderFloat( "Restitution", &m_restitution, 0.0f, 1.0f, "%.1f" ) )
		{
			rebuild = true;
		}

		if ( ImGui::SliderFloat( "Friction", &m_friction, 0.0f, 1.0f, "%.1f" ) )
		{
			rebuild = true;
		}

		if ( ImGui::SliderFloat( "Safety Factor", &m_safetyFactor, 0.01f, 0.5f, "%.2f" ) )
		{
			rebuild = true;
		}

		ImGui::PopItemWidth();

		if ( ImGui::Button( "Reset" ) )
		{
			rebuild = true;
		}

		if ( rebuild )
		{
			CreateScene();
		}

		return true;
	}

	void Step() override
	{
		Sample::Step();

		float h = 1.0f * m_count;
		DrawLine( { -h, m_dropHeight + 0.5f, 0.0f }, { h, m_dropHeight + 0.5f, 0.0f }, MakeColor( b3_colorRed ) );

		float minPercent = 0.0f;
		float maxPercent = 0.0f;
		float x = -1.0f * ( m_count - 1 );
		Vec4 white = MakeColor( b3_colorWhite );

		for ( int i = 0; i < m_count; ++i )
		{
			float total = MeasureEnergy( m_worldId, &m_bodyIds[i], 1 ).Total();

			float percent = m_startEnergy[i] != 0.0f ? 100.0f * total / m_startEnergy[i] : 0.0f;
			minPercent = i == 0 ? percent : b3MinFloat( minPercent, percent );
			maxPercent = i == 0 ? percent : b3MaxFloat( maxPercent, percent );

			DrawString3D( { x - 0.5f, m_dropHeight + 1.5f, 0.0f }, white, "%.1f%%", percent );
			x += 2.0f;
		}

		DrawTextLine( "energy: min %.2f%%, max %.2f%% of start", minPercent, maxPercent );
	}

	static Sample* Create( SampleContext* context )
	{
		return new RotatedBoxRestitution( context );
	}

	b3BodyId m_bodyIds[m_count] = {};
	float m_startEnergy[m_count] = {};
	float m_restitution = 0.9f;
	float m_friction = 0.0f;
	float m_safetyFactor = 0.5f;
};

static int sampleRotatedBoxRestitution = RegisterSample( "Restitution", "Rotated Box Restitution", RotatedBoxRestitution::Create );

// Based on https://github.com/erincatto/box2d/discussions/957
class TwoBoxRestitution : public Sample
{
public:
	explicit TwoBoxRestitution( SampleContext* context )
		: Sample( context )
	{
		if ( context->restart == false )
		{
			m_camera->SetView( 20.0f, 10.0f, 14.0f, { 0.0f, 3.0f, 0.0f } );
		}

		AddGroundBox( 10.0f );

		b3BoxHull box = b3MakeCubeHull( 0.5f );

		b3ShapeDef shapeDef = b3DefaultShapeDef();
		shapeDef.baseMaterial.restitution = 0.9f;

		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.type = b3_dynamicBody;

		bodyDef.position.y = 0.5f;
		m_bodyIds[0] = b3CreateBody( m_worldId, &bodyDef );
		b3CreateHullShape( m_bodyIds[0], &shapeDef, &box.base );

		bodyDef.position.x += 0.1f;
		bodyDef.position.y = 6.0f;
		m_bodyIds[1] = b3CreateBody( m_worldId, &bodyDef );
		b3CreateHullShape( m_bodyIds[1], &shapeDef, &box.base );

		m_startEnergy = MeasureEnergy( m_worldId, m_bodyIds, 2 ).Total();
		m_peakEnergy = m_startEnergy;
	}

	void Step() override
	{
		Sample::Step();

		MechanicalEnergy energy = MeasureEnergy( m_worldId, m_bodyIds, 2 );
		float total = energy.Total();
		m_peakEnergy = b3MaxFloat( m_peakEnergy, total );

		float scale = m_startEnergy != 0.0f ? 100.0f / m_startEnergy : 0.0f;
		DrawTextLine( "kinetic   = %.3f J linear + %.3f J angular", energy.linear, energy.angular );
		DrawTextLine( "potential = %.3f J", energy.potential );
		DrawTextLine( "total     = %.3f J (%.2f%% of start, peak %.2f%%)", total, scale * total, scale * m_peakEnergy );
	}

	static Sample* Create( SampleContext* context )
	{
		return new TwoBoxRestitution( context );
	}

	b3BodyId m_bodyIds[2] = {};
	float m_startEnergy = 0.0f;
	float m_peakEnergy = 0.0f;
};

static int sampleTwoBoxRestitution = RegisterSample( "Restitution", "Two Box Restitution", TwoBoxRestitution::Create );

class SphereRestitution : public Sample
{
public:
	explicit SphereRestitution( SampleContext* context )
		: Sample( context )
	{
		if ( context->restart == false )
		{
			m_camera->SetView( 0.0f, 15.0f, 30.0f, { 0.0f, 3.0f, 0.0f } );
		}

		AddGroundBox( 2.0f * m_count );

		b3Sphere sphere = { b3Vec3_zero, 0.5f };

		b3ShapeDef shapeDef = b3DefaultShapeDef();
		shapeDef.density = 1.0f;
		shapeDef.baseMaterial.restitution = 0.0f;

		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.type = b3_dynamicBody;

		float dr = 1.0f / ( m_count > 1 ? m_count - 1 : 1 );
		float x = -1.0f * ( m_count - 1 );
		float dx = 2.0f;

		for ( int i = 0; i < m_count; ++i )
		{
			char buffer[32];
			snprintf( buffer, 32, "%.2f", shapeDef.baseMaterial.restitution );
			bodyDef.name = buffer;

			bodyDef.position = { x, 1.0f, 0.0f };
			b3BodyId bodyId = b3CreateBody( m_worldId, &bodyDef );
			b3CreateSphereShape( bodyId, &shapeDef, &sphere );

			bodyDef.position = { x, 4.0f, 0.0f };
			bodyId = b3CreateBody( m_worldId, &bodyDef );
			b3CreateSphereShape( bodyId, &shapeDef, &sphere );

			shapeDef.baseMaterial.restitution += dr;
			x += dx;
		}
	}

	static Sample* Create( SampleContext* context )
	{
		return new SphereRestitution( context );
	}

	static constexpr int m_count = 10;
};

static int sampleSphereRestitution = RegisterSample( "Restitution", "Sphere Restitution", SphereRestitution::Create );

// Similar to the ImpulseTest unit test. The hit event marks the bounce and carries the approach speed,
// so the impulse the contact reports can be checked against reversing that speed at the coefficient.
// The total runs a little over because the contact also carries the weight for the part of the step
// it is active.
class BounceImpulse : public Sample
{
public:
	explicit BounceImpulse( SampleContext* context )
		: Sample( context )
	{
		if ( context->restart == false )
		{
			m_camera->SetView( 20.0f, 10.0f, 36.0f, { 0.0f, 8.0f, 0.0f } );
		}

		b3World_SetGravity( m_worldId, { 0.0f, -10.0f, 0.0f } );

		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.position = { 0.0f, -1.0f, 0.0f };
		b3BodyId groundId = b3CreateBody( m_worldId, &bodyDef );

		b3ShapeDef shapeDef = b3DefaultShapeDef();
		shapeDef.baseMaterial.friction = 0.0f;
		shapeDef.baseMaterial.restitution = 0.0f;
		b3BoxHull box = b3MakeBoxHull( 40.0f, 1.0f, 40.0f );
		b3ShapeId groundShapeId = b3CreateHullShape( groundId, &shapeDef, &box.base );
		SetGroundShape( groundShapeId );

		CreateScene();
	}

	void CreateScene()
	{
		if ( B3_IS_NON_NULL( m_ballId ) )
		{
			b3DestroyBody( m_ballId );
		}

		b3BodyDef bodyDef = b3DefaultBodyDef();
		bodyDef.type = b3_dynamicBody;
		bodyDef.position = { 0.0f, 0.5f + m_dropHeight, 0.0f };
		bodyDef.enableSleep = false;
		m_ballId = b3CreateBody( m_worldId, &bodyDef );

		b3ShapeDef shapeDef = b3DefaultShapeDef();
		shapeDef.baseMaterial.friction = 0.0f;
		shapeDef.baseMaterial.restitution = m_restitution;
		shapeDef.enableHitEvents = true;
		b3Sphere sphere = { b3Vec3_zero, 0.5f };
		b3CreateSphereShape( m_ballId, &shapeDef, &sphere );

		m_mass = b3Body_GetMass( m_ballId );

		m_approachSpeed = 0.0f;
		m_totalImpulse = 0.0f;
		m_expectedImpulse = 0.0f;
		m_contactSteps = 0;
		m_hit = false;
		m_bouncing = false;
	}

	bool DrawControls() override
	{
		bool rebuild = false;

		ImGui::PushItemWidth( 6.0f * ImGui::GetFontSize() );

		if ( ImGui::SliderFloat( "Restitution", &m_restitution, 0.0f, 1.0f, "%.2f" ) )
		{
			rebuild = true;
		}

		if ( ImGui::SliderFloat( "Height", &m_dropHeight, 0.5f, 50.0f, "%.1f" ) )
		{
			rebuild = true;
		}

		ImGui::PopItemWidth();

		if ( ImGui::Button( "Reset" ) )
		{
			rebuild = true;
		}

		if ( rebuild )
		{
			CreateScene();
		}

		return true;
	}

	void Step() override
	{
		Sample::Step();

		if ( m_didStep )
		{
			b3ContactEvents events = b3World_GetContactEvents( m_worldId );
			if ( m_hit == false && events.hitCount > 0 )
			{
				m_hit = true;
				m_bouncing = true;
				m_approachSpeed = events.hitEvents[0].approachSpeed;
				m_expectedImpulse = ( 1.0f + m_restitution ) * m_mass * m_approachSpeed;
			}

			// Keep summing until the contact lets go, a slow bounce can take a few steps to leave
			if ( m_bouncing )
			{
				b3ContactData contactData[4];
				int contactCount = b3Body_GetContactData( m_ballId, contactData, 4 );
				for ( int c = 0; c < contactCount; ++c )
				{
					for ( int m = 0; m < contactData[c].manifoldCount; ++m )
					{
						const b3Manifold* manifold = contactData[c].manifolds + m;
						for ( int p = 0; p < manifold->pointCount; ++p )
						{
							m_totalImpulse += manifold->points[p].totalNormalImpulse;
						}
					}
				}

				if ( contactCount > 0 )
				{
					m_contactSteps += 1;
				}
				else
				{
					m_bouncing = false;
				}
			}
		}

		float startHeight = 0.5f + m_dropHeight;
		DrawLine( { -2.0f, startHeight, 0.0f }, { 2.0f, startHeight, 0.0f }, MakeColor( b3_colorRed ) );

		DrawTextLine( "vy = %.3f m/s", b3Body_GetLinearVelocity( m_ballId ).y );

		if ( m_hit )
		{
			DrawTextLine( "approach speed = %.3f m/s", m_approachSpeed );
			DrawTextLine( "total impulse = %.2f N s over %d steps", m_totalImpulse, m_contactSteps );
			DrawTextLine( "expected impulse = %.2f N s", m_expectedImpulse );
		}
		else
		{
			DrawTextLine( "waiting for the hit" );
		}
	}

	static Sample* Create( SampleContext* context )
	{
		return new BounceImpulse( context );
	}

	b3BodyId m_ballId = b3_nullBodyId;
	float m_restitution = 0.5f;
	float m_dropHeight = 20.0f;
	float m_mass = 0.0f;
	float m_approachSpeed = 0.0f;
	float m_totalImpulse = 0.0f;
	float m_expectedImpulse = 0.0f;
	int m_contactSteps = 0;
	bool m_hit = false;
	bool m_bouncing = false;
};

static int sampleBounceImpulse = RegisterSample( "Restitution", "Bounce Impulse", BounceImpulse::Create );

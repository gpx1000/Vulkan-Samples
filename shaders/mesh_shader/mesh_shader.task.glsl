/* Copyright (c) 2023, Holochip Corporation
 *
 * SPDX-License-Identifier: Apache-2.0
 *
 * Licensed under the Apache License, Version 2.0 the "License";
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 *     http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 */

#version 450

#extension GL_EXT_shader_16bit_storage: require
#extension GL_EXT_shader_8bit_storage: require
#extension GL_EXT_mesh_shader: require
#extension GL_GOOGLE_include_directive: require

#include "mesh_shader_utils.h"

layout (constant_id = 0) const bool LATE = false;

#define CULL 1

layout(local_size_x = TASK_WG_SIZE, local_size_y = 1, local_size_z = 1) in;

layout(push_constant) uniform block
{
	Globals globals;
};

layout(binding = 0) readonly buffer TaskCommands
{
	MeshTaskCommand task_commands[];
};

layout(binding = 1) readonly buffer Draws
{
	MeshDraw draws[];
};

layout(binding = 2) readonly buffer Meshlets
{
	Meshlet meshlets[];
};

layout(binding = 5) buffer MeshletVisibility
{
	uint meshlet_visibility[];
};

layout(binding = 6) uniform sampler2D depth_pyramid;

taskPayloadSharedEXT MeshTaskPayload payload;

#if CULL
shared int shared_count;
#endif

const float cut_off_coefficient_inverse = 1.0f / 127.0f;

void main()
{
	MeshTaskCommand command = task_commands[gl_WorkGroupID.x * 64 + gl_WorkGroupID.y];
	uint draw_id = command.draw_id;
	MeshDraw mesh_draw = draws[draw_id];

	uint late_draw_visibility = command.late_draw_visibility;
	uint task_count = command.task_count;

	uint mg_index = gl_LocalInvocationID.x;
	uint m_index = mg_index + command.taskOffset;
	uint mv_index = mg_index + command.meshletVisibilityOffset;

#if CULL
	shared_count = 0;
	barrier();

	vec3 center = rotate_quaternion(meshlets[m_index].center, mesh_draw.orientation) * mesh_draw.scale + mesh_draw.position;
	float radius = meshlets[m_index].radius * mesh_draw.scale;

	vec3 cone_axis = rotate_quaternion(vec3(cut_off_coefficient_inverse * int(meshlets[m_index].cone_axis[0]), int(meshlets[m_index].cone_axis[1]), int(meshlets[m_index].cone_axis[2])), mesh_draw.orientation);
	float cone_cutoff = cut_off_coefficient_inverse * meshlets[m_index].cone_cutoff);

	bool valid = mg_index < task_count;
	bool visible = valid;
	bool skip = false;

	if (globals.cluster_occlusion_enabled == 1)
	{
		uint meshlet_visibility_bit = meshlet_visibility[mv_index >> 5] & (1u << (mv_index & 31));

		if (!LATE && meshlet_visibility_bit == 0)
		{
			visible = false;
        }

		if (LATE && late_draw_visibility == 1 && meshlet_visibility_bit != 0)
		{
			skip = true;
		}
	}

	visible = visible && !cone_cull(center, radius, cone_axis, cone_cutoff, vec3(0, 0, 0));

	visible = visible && ( center.z * globals.frustum[1] - abs(center.x) * globals.frustum[0] > (-1.0f) * radius );
	visible = visible && ( center.z * globals.frustum[3] - abs(center.y) * globals.frustum[2] > (-1.0f) * radius );
	visible = visible && ( center.z + radius > globals.z_near && center.z - radius < globals.z_far );

	if (LATE && globals.cluster_occlusion_enabled == 1 && visible)
	{
		float P00 = globals.projection[0][0], P11 = globals.projection[1][1];

		vec4 aabb;
		if (project_sphere(center, radius, globals.z_near, P00, P11, aabb))
		{
			float width = (aabb.z - aabb.x) * globals.pyramidWidth;
			float height = (aabb.w - aabb.y) * globals.pyramidHeight;

			float level = floor(log2(max(width, height)));

			float depth = textureLod(depth_pyramid, (aabb.xy + aabb.zw) * 0.5, level).x;
			float depth_sphere = globals.z_near / (center.z - radius);

			visible = visible && depth_sphere > depth;
		}
	}

	if (LATE && globals.cluster_occlusion_enabled == 1 && valid)
	{
		if (visible)
		{
			atomicOr(meshlet_visibility[mv_index >> 5], 1u << (mv_index & 31));
		}
		else
		{
			atomicAnd(meshlet_visibility[mv_index >> 5], ~(1u << (mv_index & 31)));
		}
	}

	if (visible && !skip)
	{
		uint index = atomicAdd(shared_count, 1);

		payload.meshlet_indices[index] = m_index;
	}

	payload.draw_id = draw_id;

	barrier();
	EmitMeshTasksEXT(shared_count, 1, 1);
#else
	payload.draw_id = draw_id;
	payload.meshlet_indices[gl_LocalInvocationID.x] = m_index;

	EmitMeshTasksEXT(task_count, 1, 1);
#endif
}

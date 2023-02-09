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

#define DEBUG 0
#define CULL 1

layout(local_size_x = MESH_WG_SIZE, local_size_y = 1, local_size_z = 1) in;
layout(triangles, max_vertices = 64, max_primitives = 64) out;

layout(push_constant) uniform block
{
	Globals globals;
};

layout(binding = 1) readonly buffer Draws
{
	MeshDraw draws[];
};

layout(binding = 2) readonly buffer Meshlets
{
	Meshlet meshlets[];
};

layout(binding = 3) readonly buffer MeshletData
{
	uint meshlet_data[];
};

layout(binding = 3) readonly buffer MeshletData8
{
	uint8_t meshlet_data_8[];
};

layout(binding = 4) readonly buffer Vertices
{
	Vertex vertices[];
};

layout(location = 0) out vec4 color[];

taskPayloadSharedEXT MeshTaskPayload payload;

uint hash(uint a)
{
   a = (a+0x7ed55d16) + (a<<12);
   a = (a^0xc761c23c) ^ (a>>19);
   a = (a+0x165667b1) + (a<<5);
   a = (a+0xd3a2646c) ^ (a<<9);
   a = (a+0xfd7046c5) + (a<<3);
   a = (a^0xb55a4f09) ^ (a>>16);
   return a;
}

#if CULL
shared vec3 vertex_clip[64];
#endif

// if Subpixel Precision in, then: 1.0f / (2.0f^subpixel.precision_bits)
const float subpixel_precision = 1.0f / 256.0f;

void main()
{
	uint t_index = gl_LocalInvocationIndex;
	uint m_index = payload.meshletIndices[gl_WorkGroupID.x];

	MeshDraw mesh_draw = draws[payload.drawId];

	uint vertex_count = uint(meshlets[m_index].vertex_count);
	uint triangle_count = uint(meshlets[m_index].triangle_count);

	SetMeshOutputsEXT(vertex_count, triangle_count);

	uint data_offset = meshlets[m_index].data_offset;
	uint vertex_offset = data_offset;
	uint index_offset = data_offset + vertex_count;

#if DEBUG
	uint m_hash = hash(m_index);
	vec3 m_color = vec3(float(m_hash & 255), float((m_hash >> 8) & 255), float((m_hash >> 16) & 255)) / 255.0;
#endif

	vec2 screen = vec2(globals.screen_width, globals.screen_height);

	if (t_index < vertex_count)
	{
		uint i = t_index;
		uint vi = meshlet_data[vertex_offset + i] + mesh_draw.vertex_offset;

		vec3 position = vec3(vertices[vi].vx, vertices[vi].vy, vertices[vi].vz);
		vec3 normal = vec3(int(vertices[vi].nx), int(vertices[vi].ny), int(vertices[vi].nz)) / 127.0 - 1.0;
		vec2 tex_coord = vec2(vertices[vi].tu, vertices[vi].tv);

		vec4 clip = globals.projection * vec4(rotate_quaternion(position, mesh_draw.orientation) * mesh_draw.scale + mesh_draw.position, 1);

		gl_MeshVerticesEXT[i].gl_Position = clip;
		color[i] = vec4(normal * 0.5 + vec3(0.5), 1.0);

	#if CULL
		vertex_clip[i] = vec3((clip.xy / clip.w * 0.5 + vec2(0.5)) * screen, clip.w);
	#endif

	#if DEBUG
		color[i] = vec4(m_color, 1.0);
	#endif
	}

#if CULL
	barrier();
#endif

	if (t_index < triangleCount)
	{
		uint i = t_index;
		uint offset = index_offset * 4 + i * 3;
		uint a = uint(meshlet_data_8[offset]), b = uint(meshlet_data_8[offset + 1]), c = uint(meshlet_data_8[offset + 2]);

		gl_PrimitiveTriangleIndicesEXT[i] = uvec3(a, b, c);

	#if CULL
		bool culled = false;

		vec2 pa = vertex_clip[a].xy, pb = vertex_clip[b].xy, pc = vertex_clip[c].xy;

		vec2 eb = pb - pa;
		vec2 ec = pc - pa;

		culled = culled || (eb.x * ec.y >= eb.y * ec.x);

		vec2 b_min = min(pa, min(pb, pc));
		vec2 b_max = max(pa, max(pb, pc));

		culled = culled || (round(b_min.x - subpixel_precision) == round(b_max.x) || round(b_min.y) == round(b_max.y + subpixel_precision));
		culled = culled && (vertex_clip[a].z > 0 && vertex_clip[b].z > 0 && vertex_clip[c].z > 0);

		gl_MeshPrimitivesEXT[i].gl_CullPrimitiveEXT = culled;
	#endif
	}
}

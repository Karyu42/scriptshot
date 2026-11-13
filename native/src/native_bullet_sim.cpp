#include "native_bullet_sim.h"

#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/core/object.hpp>

#include <algorithm>
#include <cmath>
#include <limits>

using namespace godot;

namespace scriptshot {

static const double INF_D = std::numeric_limits<double>::infinity();

NativeBulletSim::NativeBulletSim() {
	bounds = Rect2(-2048, -2048, 4096, 4096);
}

void NativeBulletSim::_bind_methods() {
	ClassDB::bind_method(D_METHOD("configure", "capacity", "bounds", "cell_size", "max_speed"), &NativeBulletSim::configure);
	ClassDB::bind_method(D_METHOD("set_limits", "cap", "reserve"), &NativeBulletSim::set_limits);
	ClassDB::bind_method(D_METHOD("set_bounds", "bounds"), &NativeBulletSim::set_bounds);
	ClassDB::bind_method(D_METHOD("set_external_count", "count"), &NativeBulletSim::set_external_count);
	ClassDB::bind_method(D_METHOD("add_wall", "rect"), &NativeBulletSim::add_wall);
	ClassDB::bind_method(D_METHOD("clear_walls"), &NativeBulletSim::clear_walls);
	ClassDB::bind_method(D_METHOD("get_wall_count"), &NativeBulletSim::get_wall_count);
	ClassDB::bind_method(D_METHOD("set_targets", "pos", "radius", "layer", "ids", "count"), &NativeBulletSim::set_targets);
	ClassDB::bind_method(D_METHOD("step", "delta"), &NativeBulletSim::step);
	ClassDB::bind_method(D_METHOD("integrate", "delta"), &NativeBulletSim::integrate);
	ClassDB::bind_method(D_METHOD("collide"), &NativeBulletSim::collide);
	ClassDB::bind_method(D_METHOD("integrate_would_die", "id", "delta"), &NativeBulletSim::integrate_would_die);
	ClassDB::bind_method(D_METHOD("get_reflect_count_of", "id"), &NativeBulletSim::get_reflect_count_of);
	ClassDB::bind_method(D_METHOD("apply_script_reflect", "id", "new_owner", "new_mask", "color", "new_damage", "keep_script", "reverse", "limit"),
			&NativeBulletSim::apply_script_reflect);
	ClassDB::bind_method(D_METHOD("deliver_hits"), &NativeBulletSim::deliver_hits);
	ClassDB::bind_method(D_METHOD("upload", "multimesh", "allocated", "interpolate", "stretch"), &NativeBulletSim::upload);
	ClassDB::bind_method(D_METHOD("spawn", "position", "velocity", "angle", "lifetime", "radius", "damage", "hit_mask", "color",
								"acceleration", "turn_rate", "pierce", "collide_world", "owner_layer", "source_flags", "seq",
								"behavior", "param_a", "param_b"),
			&NativeBulletSim::spawn);
	ClassDB::bind_method(D_METHOD("gather_batch", "behavior"), &NativeBulletSim::gather_batch);
	ClassDB::bind_method(D_METHOD("apply_batch", "ids", "vx", "vy", "pa", "pb"), &NativeBulletSim::apply_batch);
	ClassDB::bind_method(D_METHOD("teleport_id", "id", "x", "y"), &NativeBulletSim::teleport_id);
	ClassDB::bind_method(D_METHOD("count_with_behavior", "behavior"), &NativeBulletSim::count_with_behavior);
	ClassDB::bind_method(D_METHOD("get_invalid_total"), &NativeBulletSim::get_invalid_total);
	ClassDB::bind_method(D_METHOD("set_retire_callback", "callback"), &NativeBulletSim::set_retire_callback);
	ClassDB::bind_method(D_METHOD("get_pending_hit_count"), &NativeBulletSim::get_pending_hit_count);
	ClassDB::bind_method(D_METHOD("get_pending_hit_seqs"), &NativeBulletSim::get_pending_hit_seqs);
	ClassDB::bind_method(D_METHOD("get_pending_hit_t"), &NativeBulletSim::get_pending_hit_t);
	ClassDB::bind_method(D_METHOD("commit_pending_hit", "index"), &NativeBulletSim::commit_pending_hit);
	ClassDB::bind_method(D_METHOD("finish_delivery"), &NativeBulletSim::finish_delivery);
	ClassDB::bind_method(D_METHOD("find_seq", "seq"), &NativeBulletSim::find_seq);
	ClassDB::bind_method(D_METHOD("set_seq_at", "slot", "seq"), &NativeBulletSim::set_seq_at);
	ClassDB::bind_method(D_METHOD("export_states"), &NativeBulletSim::export_states);
	ClassDB::bind_method(D_METHOD("extract_behavior", "behavior"), &NativeBulletSim::extract_behavior);
	ClassDB::bind_method(D_METHOD("get_velocity_of", "id"), &NativeBulletSim::get_velocity_of);
	ClassDB::bind_method(D_METHOD("get_param_a_of", "id"), &NativeBulletSim::get_param_a_of);
	ClassDB::bind_method(D_METHOD("get_param_b_of", "id"), &NativeBulletSim::get_param_b_of);
	ClassDB::bind_method(D_METHOD("set_zones", "pos", "radius", "owners", "count"), &NativeBulletSim::set_zones);
	ClassDB::bind_method(D_METHOD("get_zone_hit_count"), &NativeBulletSim::get_zone_hit_count);
	ClassDB::bind_method(D_METHOD("get_zone_hit_slots"), &NativeBulletSim::get_zone_hit_slots);
	ClassDB::bind_method(D_METHOD("get_zone_hit_zones"), &NativeBulletSim::get_zone_hit_zones);
	ClassDB::bind_method(D_METHOD("get_zone_hit_t"), &NativeBulletSim::get_zone_hit_t);
	ClassDB::bind_method(D_METHOD("get_zone_hit_seqs"), &NativeBulletSim::get_zone_hit_seqs);
	ClassDB::bind_method(D_METHOD("get_position_at", "slot"), &NativeBulletSim::get_position_at);
	ClassDB::bind_method(D_METHOD("get_previous_at", "slot"), &NativeBulletSim::get_previous_at);
	ClassDB::bind_method(D_METHOD("get_velocity_at", "slot"), &NativeBulletSim::get_velocity_at);
	ClassDB::bind_method(D_METHOD("get_owner_at", "slot"), &NativeBulletSim::get_owner_at);
	ClassDB::bind_method(D_METHOD("get_reflect_count_at", "slot"), &NativeBulletSim::get_reflect_count_at);
	ClassDB::bind_method(D_METHOD("get_wall_clip_at", "slot"), &NativeBulletSim::get_wall_clip_at);
	ClassDB::bind_method(D_METHOD("is_slot_alive", "slot"), &NativeBulletSim::is_slot_alive);
	ClassDB::bind_method(D_METHOD("apply_reflect", "slot", "new_owner", "new_mask", "color", "new_damage", "keep_script", "limit", "heading", "speed", "impact"),
			&NativeBulletSim::apply_reflect);
	ClassDB::bind_method(D_METHOD("cancel_outbound_wall", "slot"), &NativeBulletSim::cancel_outbound_wall);
	ClassDB::bind_method(D_METHOD("begin_return", "slot", "delta", "reflected_t"), &NativeBulletSim::begin_return);
	ClassDB::bind_method(D_METHOD("get_return_hit_count"), &NativeBulletSim::get_return_hit_count);
	ClassDB::bind_method(D_METHOD("commit_return_hit", "index"), &NativeBulletSim::commit_return_hit);
	ClassDB::bind_method(D_METHOD("finish_return", "slot"), &NativeBulletSim::finish_return);
	ClassDB::bind_method(D_METHOD("get_wall_normal", "id"), &NativeBulletSim::get_wall_normal);
	ClassDB::bind_method(D_METHOD("clear_wall_normals"), &NativeBulletSim::clear_wall_normals);
	ClassDB::bind_method(D_METHOD("query_wall_normal", "start", "delta", "radius"), &NativeBulletSim::query_wall_normal);
	ClassDB::bind_method(D_METHOD("is_alive", "id"), &NativeBulletSim::is_alive);
	ClassDB::bind_method(D_METHOD("slot_of", "id"), &NativeBulletSim::slot_of);
	ClassDB::bind_method(D_METHOD("id_of", "slot"), &NativeBulletSim::id_of);
	ClassDB::bind_method(D_METHOD("kill", "id"), &NativeBulletSim::kill);
	ClassDB::bind_method(D_METHOD("compact"), &NativeBulletSim::compact);
	ClassDB::bind_method(D_METHOD("clear"), &NativeBulletSim::clear);
	ClassDB::bind_method(D_METHOD("get_count"), &NativeBulletSim::get_count);
	ClassDB::bind_method(D_METHOD("get_capacity"), &NativeBulletSim::get_capacity);
	ClassDB::bind_method(D_METHOD("get_logical_cap"), &NativeBulletSim::get_logical_cap);
	ClassDB::bind_method(D_METHOD("get_enemy_reserve"), &NativeBulletSim::get_enemy_reserve);
	ClassDB::bind_method(D_METHOD("get_spawned_total"), &NativeBulletSim::get_spawned_total);
	ClassDB::bind_method(D_METHOD("get_dropped_total"), &NativeBulletSim::get_dropped_total);
	ClassDB::bind_method(D_METHOD("get_owner_count", "layer"), &NativeBulletSim::get_owner_count);
	ClassDB::bind_method(D_METHOD("get_owner_counts"), &NativeBulletSim::get_owner_counts);
	ClassDB::bind_method(D_METHOD("get_dropped_by_owner"), &NativeBulletSim::get_dropped_by_owner);
	ClassDB::bind_method(D_METHOD("get_dropped_by_limit"), &NativeBulletSim::get_dropped_by_limit);
	ClassDB::bind_method(D_METHOD("get_max_radius"), &NativeBulletSim::get_max_radius);
	ClassDB::bind_method(D_METHOD("get_last_hit_count"), &NativeBulletSim::get_last_hit_count);
	ClassDB::bind_method(D_METHOD("get_last_wall_hit_count"), &NativeBulletSim::get_last_wall_hit_count);
	ClassDB::bind_method(D_METHOD("get_despawn_counts"), &NativeBulletSim::get_despawn_counts);
	ClassDB::bind_method(D_METHOD("snapshot"), &NativeBulletSim::snapshot);
	ClassDB::bind_method(D_METHOD("set_record_events", "on"), &NativeBulletSim::set_record_events);
	ClassDB::bind_method(D_METHOD("get_last_hits"), &NativeBulletSim::get_last_hits);
	ClassDB::bind_method(D_METHOD("get_last_despawns"), &NativeBulletSim::get_last_despawns);

	BIND_ENUM_CONSTANT(REASON_LIFETIME);
	BIND_ENUM_CONSTANT(REASON_BOUNDS);
	BIND_ENUM_CONSTANT(REASON_HIT);
	BIND_ENUM_CONSTANT(REASON_MANUAL);
	BIND_ENUM_CONSTANT(REASON_CLEARED);
	BIND_ENUM_CONSTANT(REASON_WALL);
	BIND_ENUM_CONSTANT(REASON_INVALID);
	BIND_ENUM_CONSTANT(REASON_ABSORBED);
}

// ---------------------------------------------------------------------------
// setup
// ---------------------------------------------------------------------------

void NativeBulletSim::configure(int p_capacity, const Rect2 &p_bounds, float p_cell_size, float p_max_speed) {
	ERR_FAIL_COND(p_capacity <= 0);
	ERR_FAIL_COND(p_cell_size <= 0.0f);
	capacity = p_capacity;
	count = 0;
	bounds = p_bounds;
	cell_size = p_cell_size;
	max_speed = (p_max_speed > 0.0f && std::isfinite(p_max_speed)) ? p_max_speed : 0.0f;
	inv_cell = 1.0f / cell_size;
	cols = std::max(1, (int)std::ceil(bounds.size.x * inv_cell));
	rows = std::max(1, (int)std::ceil(bounds.size.y * inv_cell));
	const size_t n = (size_t)capacity;
	for (auto *v : { &px, &py, &qx, &qy, &vx, &vy, &rx, &ry, &radius, &age, &lifetime, &accel, &turn, &damage, &param_a, &param_b }) {
		v->assign(n, 0.0f);
	}
	col.assign(n * 4, 1.0f);
	hit_mask.assign(n, 0);
	pierce.assign(n, 0);
	owner_layer.assign(n, 0);
	seq.assign(n, 0);
	behavior.assign(n, 0);
	collide_world.assign(n, 1);
	dead.assign(n, 0);
	source_flags.assign(n, 0);
	reflect_count.assign(n, 0);
	wall_clip.assign(n, 1.0f);
	wall_nx.assign(n, 0.0f);
	wall_ny.assign(n, 0.0f);
	wall_suppress.assign(n, 0);
	wall_report.assign(n, 0);
	return_wall_pending.assign(n, 0);
	hit_mem.assign(n * (size_t)HIT_MEMORY, 0);
	hit_mem_count.assign(n, 0);
	hit_mem_head.assign(n, 0);
	handle_of_slot.assign(n, 0);
	pending.assign(n, 0);
	pending_count = 0;
	slot_of_handle.assign(n, -1);
	generation.assign(n, 1);
	free_handles.assign(n, 0);
	reset_handles();
	t_heads.assign((size_t)cols * rows, -1);
	t_occupied.assign((size_t)cols * rows, 0);
	t_touched.clear();
	t_entry_count = 0;
	resize_zone_grid();
	walls_dirty = true;
	hit_events.reserve(1024);
	for (int s = 0; s < 2; s++) {
		cur_buf[s].clear();
		prev_buf[s].clear();
	}
	spawned_total = dropped_total = invalid_total = 0;
	logical_cap = capacity;
	enemy_reserve = 0;
	other_limit = capacity;
	external_count = 0;
	for (int k = 0; k < 3; k++) {
		owner_counts[k] = 0;
		dropped_by_owner[k] = 0;
	}
	dropped_by_limit[0] = dropped_by_limit[1] = 0;
	max_radius = 0.0f;
	min_target_radius = std::numeric_limits<float>::infinity();
	for (auto &c : despawn_counts) {
		c = 0;
	}
}

void NativeBulletSim::set_limits(int p_cap, int p_reserve) {
	logical_cap = std::clamp(p_cap, 0, capacity);
	enemy_reserve = std::clamp(p_reserve, 0, logical_cap);
	other_limit = logical_cap - enemy_reserve;
}

void NativeBulletSim::set_bounds(const Rect2 &p_bounds) {
	if (p_bounds.size.x <= 0.0f || p_bounds.size.y <= 0.0f) {
		return;
	}
	bounds = p_bounds;
	cols = std::max(1, (int)std::ceil(bounds.size.x * inv_cell));
	rows = std::max(1, (int)std::ceil(bounds.size.y * inv_cell));
	t_heads.assign((size_t)cols * (size_t)rows, -1);
	t_occupied.assign((size_t)cols * (size_t)rows, 0);
	t_touched.clear();
	resize_zone_grid();
	walls_dirty = true;
}

void NativeBulletSim::set_external_count(int p_count) {
	external_count = std::max(p_count, 0);
}

int NativeBulletSim::owner_slot_of(int layer) const {
	if ((layer & LAYER_PLAYER) != 0) {
		return OWNER_PLAYER;
	}
	if ((layer & LAYER_ENEMY) != 0) {
		return OWNER_ENEMY;
	}
	return OWNER_NONE;
}

void NativeBulletSim::note_drop(int owner_slot, bool at_cap) {
	dropped_total++;
	if (owner_slot >= 0 && owner_slot < 3) {
		dropped_by_owner[owner_slot]++;
	}
	dropped_by_limit[at_cap ? DROP_LOGICAL_CAP : DROP_ENEMY_RESERVE]++;
}

void NativeBulletSim::reset_handles() {
	std::fill(generation.begin(), generation.end(), 1u);
	std::fill(slot_of_handle.begin(), slot_of_handle.end(), -1);
	for (int k = 0; k < capacity; k++) {
		free_handles[k] = capacity - 1 - k; // pop order: handle 0 first
	}
	free_count = capacity;
}

void NativeBulletSim::add_wall(const Rect2 &p_rect) {
	Rect2 r = p_rect.abs();
	wall_lo_x.push_back(r.position.x);
	wall_lo_y.push_back(r.position.y);
	wall_hi_x.push_back(r.position.x + r.size.x);
	wall_hi_y.push_back(r.position.y + r.size.y);
	walls_dirty = true;
}

void NativeBulletSim::clear_walls() {
	wall_lo_x.clear();
	wall_lo_y.clear();
	wall_hi_x.clear();
	wall_hi_y.clear();
	walls_dirty = true;
}

void NativeBulletSim::rebuild_walls() {
	const size_t cells = (size_t)cols * rows;
	std::vector<int32_t> counts(cells + 1, 0);
	const int n = (int)wall_lo_x.size();
	auto cell_range = [&](int w, int &x0, int &x1, int &y0, int &y1) {
		x0 = std::clamp((int)std::floor((wall_lo_x[w] - bounds.position.x) * inv_cell), 0, cols - 1);
		x1 = std::clamp((int)std::floor((wall_hi_x[w] - bounds.position.x) * inv_cell), 0, cols - 1);
		y0 = std::clamp((int)std::floor((wall_lo_y[w] - bounds.position.y) * inv_cell), 0, rows - 1);
		y1 = std::clamp((int)std::floor((wall_hi_y[w] - bounds.position.y) * inv_cell), 0, rows - 1);
	};
	for (int w = 0; w < n; w++) {
		int x0, x1, y0, y1;
		cell_range(w, x0, x1, y0, y1);
		for (int cy = y0; cy <= y1; cy++) {
			for (int cx = x0; cx <= x1; cx++) {
				counts[(size_t)cy * cols + cx + 1]++;
			}
		}
	}
	for (size_t c = 0; c < cells; c++) {
		counts[c + 1] += counts[c];
	}
	w_cell_start = counts;
	w_cell_walls.assign((size_t)counts[cells], 0);
	std::vector<int32_t> fill(cells, 0);
	for (int w = 0; w < n; w++) {
		int x0, x1, y0, y1;
		cell_range(w, x0, x1, y0, y1);
		for (int cy = y0; cy <= y1; cy++) {
			for (int cx = x0; cx <= x1; cx++) {
				size_t c = (size_t)cy * cols + cx;
				w_cell_walls[(size_t)w_cell_start[c] + fill[c]++] = w;
			}
		}
	}
	walls_dirty = false;
}

// ---------------------------------------------------------------------------
// targets / hurtbox spatial hash
// ---------------------------------------------------------------------------

void NativeBulletSim::set_targets(const PackedVector2Array &p_pos, const PackedFloat32Array &p_radius,
		const PackedInt32Array &p_layer, const PackedInt64Array &p_ids, int p_count) {
	p_count = std::min(p_count, (int)std::min({ p_pos.size(), p_radius.size(), p_layer.size(), p_ids.size() }));
	target_count = std::max(p_count, 0);
	targets.resize((size_t)target_count);
	const Vector2 *pp = p_pos.ptr();
	const float *pr = p_radius.ptr();
	const int32_t *pl = p_layer.ptr();
	const int64_t *pi = p_ids.ptr();
	min_target_radius = std::numeric_limits<float>::infinity();
	for (int k = 0; k < target_count; k++) {
		targets[k] = Target{ pp[k].x, pp[k].y, pr[k], pl[k], (uint64_t)pi[k] };
		if (pr[k] < min_target_radius) {
			min_target_radius = pr[k];
		}
	}
}

void NativeBulletSim::rebuild_hash() {
	for (int32_t cell : t_touched) {
		t_heads[cell] = -1;
		t_occupied[cell] = 0;
	}
	t_touched.clear();
	t_entry_count = 0;
	const float margin = max_radius;
	for (int id = 0; id < target_count; id++) {
		const Target &t = targets[id];
		const float reach = t.r + margin;
		int x0 = std::clamp((int)std::floor((t.x - reach - bounds.position.x) * inv_cell), 0, cols - 1);
		int x1 = std::clamp((int)std::floor((t.x + reach - bounds.position.x) * inv_cell), 0, cols - 1);
		int y0 = std::clamp((int)std::floor((t.y - reach - bounds.position.y) * inv_cell), 0, rows - 1);
		int y1 = std::clamp((int)std::floor((t.y + reach - bounds.position.y) * inv_cell), 0, rows - 1);
		for (int cy = y0; cy <= y1; cy++) {
			for (int cx = x0; cx <= x1; cx++) {
				const int cell = cy * cols + cx;
				if ((size_t)t_entry_count >= t_entry_target.size()) {
					size_t ns = std::max<size_t>(256, t_entry_target.size() * 2);
					t_entry_target.resize(ns);
					t_entry_next.resize(ns);
				}
				const int e = t_entry_count++;
				t_entry_target[e] = id;
				t_entry_next[e] = t_heads[cell];
				if (!t_occupied[cell]) {
					t_occupied[cell] = 1;
					t_touched.push_back(cell);
				}
				t_heads[cell] = e;
			}
		}
	}
}

// Earliest contact of the circle of radius `r` moving along s + d*t, t in
// [0, 1], with a target on a layer in `mask` (skipping the instance id `last`
// and the target indices in `excl`, and any instance id in the bullet's
// hit-memory ring). Returns the target index or -1 and sets r_t.
//
// Grid traversal visits the cells under the path in order of entry time and
// keeps going until the next cell is entered at or after the best hit so far,
// so a nearer target in a later cell is never missed (a bigger target found
// first in an earlier cell does not shadow it).
int NativeBulletSim::sweep_targets(double sx, double sy, double dx, double dy, double r, int mask, int slot,
		const int32_t *excl, int excl_n, double &r_t) const {
	// Clip the segment to the grid rectangle: [t0, t1].
	const double ox = bounds.position.x, oy = bounds.position.y;
	const double gx1 = ox + (double)cols * cell_size, gy1 = oy + (double)rows * cell_size;
	double t0 = 0.0, t1 = 1.0;
	for (int axis = 0; axis < 2; axis++) {
		const double s = axis == 0 ? sx : sy;
		const double d = axis == 0 ? dx : dy;
		const double lo = axis == 0 ? ox : oy;
		const double hi = axis == 0 ? gx1 : gy1;
		if (std::fabs(d) < 1e-12) {
			if (s < lo || s >= hi) {
				return -1;
			}
		} else {
			double a = (lo - s) / d, b = (hi - s) / d;
			if (a > b) {
				std::swap(a, b);
			}
			t0 = std::max(t0, a);
			t1 = std::min(t1, b);
			if (t0 > t1) {
				return -1;
			}
		}
	}
	const double inv = inv_cell;
	const double fx0 = (sx - ox) * inv, fy0 = (sy - oy) * inv;
	const double dfx = dx * inv, dfy = dy * inv;
	auto clamp_cell = [](double v, int hi) { return std::clamp((int)std::floor(v), 0, hi); };
	int cx = clamp_cell(fx0 + dfx * t0, cols - 1);
	int cy = clamp_cell(fy0 + dfy * t0, rows - 1);
	const int ex = clamp_cell(fx0 + dfx * t1, cols - 1);
	const int ey = clamp_cell(fy0 + dfy * t1, rows - 1);
	const int step_x = dx > 0.0 ? 1 : -1;
	const int step_y = dy > 0.0 ? 1 : -1;
	double tmax_x = INF_D, tmax_y = INF_D, tdelta_x = INF_D, tdelta_y = INF_D;
	if (dfx != 0.0) {
		tdelta_x = std::fabs(1.0 / dfx);
		tmax_x = ((double)(cx + (step_x > 0 ? 1 : 0)) - fx0) / dfx;
	}
	if (dfy != 0.0) {
		tdelta_y = std::fabs(1.0 / dfy);
		tmax_y = ((double)(cy + (step_y > 0 ? 1 : 0)) - fy0) / dfy;
	}
	const double a = dx * dx + dy * dy;
	double best_t = 2.0;
	int best = -1;
	double t_entry = t0;
	const int steps = std::abs(ex - cx) + std::abs(ey - cy) + 1;
	for (int stp = 0; stp < steps; stp++) {
		if (best >= 0 && t_entry >= best_t) {
			break; // every remaining cell starts after the best hit
		}
		const int cell = cy * cols + cx;
		if (t_occupied[cell]) {
			for (int e = t_heads[cell]; e != -1; e = t_entry_next[e]) {
				const int ti = t_entry_target[e];
				const Target &t = targets[ti];
				if ((t.layer & mask) == 0 || is_remembered(slot, t.id)) {
					continue;
				}
				bool skip = false;
				for (int k = 0; k < excl_n; k++) {
					if (excl[k] == ti) {
						skip = true;
						break;
					}
				}
				if (skip) {
					continue;
				}
				const double rr = (double)t.r + r;
				const double fx = sx - t.x, fy = sy - t.y;
				const double c = fx * fx + fy * fy - rr * rr;
				double hit = -1.0;
				if (c <= 0.0) {
					hit = 0.0;
				} else if (a > 0.0) {
					const double b = fx * dx + fy * dy;
					const double disc = b * b - a * c;
					if (disc >= 0.0 && b < 0.0) {
						hit = (-b - std::sqrt(disc)) / a;
					}
				}
				if (hit >= 0.0 && hit <= 1.0 && hit < best_t) {
					best_t = hit;
					best = ti;
				}
			}
		}
		// Advance along the axis whose next cell border comes first, never
		// past the end cell.
		if (cx == ex || (cy != ey && tmax_y < tmax_x)) {
			t_entry = tmax_y;
			cy += step_y;
			tmax_y += tdelta_y;
		} else {
			t_entry = tmax_x;
			cx += step_x;
			tmax_x += tdelta_x;
		}
	}
	r_t = best_t;
	return best;
}

// Endpoint overlap, matching HurtboxGrid's short-path point test: the first
// target in the end cell that contains the point, reported at the end position
// (t = 1), not at the swept contact. A remembered pierce target is skipped.
bool NativeBulletSim::point_hit(double x, double y, double r, int mask, int slot, int &r_target) const {
	const double fx = (x - bounds.position.x) * inv_cell;
	const double fy = (y - bounds.position.y) * inv_cell;
	if (fx < 0.0 || fy < 0.0) {
		return false;
	}
	const int cx = (int)std::floor(fx);
	const int cy = (int)std::floor(fy);
	if (cx >= cols || cy >= rows) {
		return false;
	}
	const int cell = cy * cols + cx;
	if (!t_occupied[cell]) {
		return false;
	}
	for (int e = t_heads[cell]; e != -1; e = t_entry_next[e]) {
		const int ti = t_entry_target[e];
		const Target &t = targets[ti];
		if ((t.layer & mask) == 0 || is_remembered(slot, t.id)) {
			continue;
		}
		const double rr = (double)t.r + r;
		const double dx = x - t.x;
		const double dy = y - t.y;
		if (dx * dx + dy * dy <= rr * rr) {
			r_target = ti;
			return true;
		}
	}
	return false;
}

// ---------------------------------------------------------------------------
// walls
// ---------------------------------------------------------------------------

// Outward unit normal of the inflated box face the path enters through.
// Same rules as WallGrid.box_normal, including the corner and inside ties.
void NativeBulletSim::box_normal(float sx, float sy, float dx, float dy, float lox, float loy, float hix, float hiy, float &nx, float &ny) {
	float tx = -std::numeric_limits<float>::infinity();
	float ty = -std::numeric_limits<float>::infinity();
	float nnx = 0.0f;
	float nny = 0.0f;
	if (std::fabs(dx) >= 1e-9f) {
		if (dx > 0.0f) {
			tx = (lox - sx) / dx;
			nnx = -1.0f;
		} else {
			tx = (hix - sx) / dx;
			nnx = 1.0f;
		}
	}
	if (std::fabs(dy) >= 1e-9f) {
		if (dy > 0.0f) {
			ty = (loy - sy) / dy;
			nny = -1.0f;
		} else {
			ty = (hiy - sy) / dy;
			nny = 1.0f;
		}
	}
	if (tx <= 0.0f && ty <= 0.0f) {
		const float left = sx - lox;
		const float right = hix - sx;
		const float top = sy - loy;
		const float bottom = hiy - sy;
		const float m = std::min(std::min(left, right), std::min(top, bottom));
		if (m == left) {
			nx = -1.0f;
			ny = 0.0f;
			return;
		}
		if (m == right) {
			nx = 1.0f;
			ny = 0.0f;
			return;
		}
		if (m == top) {
			nx = 0.0f;
			ny = -1.0f;
			return;
		}
		nx = 0.0f;
		ny = 1.0f;
		return;
	}
	if (tx > ty) {
		nx = nnx;
		ny = 0.0f;
		return;
	}
	if (ty > tx) {
		nx = 0.0f;
		ny = nny;
		return;
	}
	if (std::fabs(dx) >= std::fabs(dy)) {
		nx = nnx;
		ny = 0.0f;
		return;
	}
	nx = 0.0f;
	ny = nny;
}

// First contact with any wall grown by `r`. On an exact time tie the lower wall
// index wins, matching WallGrid._best_hit, so the normal does not follow cell order.
NativeBulletSim::WallContact NativeBulletSim::query_wall(double sx, double sy, double dx, double dy, double r) const {
	WallContact out;
	if (wall_lo_x.empty() || w_cell_start.empty()) {
		return out;
	}
	const double ex = sx + dx, ey = sy + dy;
	const double minx = std::min(sx, ex) - r, maxx = std::max(sx, ex) + r;
	const double miny = std::min(sy, ey) - r, maxy = std::max(sy, ey) + r;
	const int x0 = std::clamp((int)std::floor((minx - bounds.position.x) * inv_cell), 0, cols - 1);
	const int x1 = std::clamp((int)std::floor((maxx - bounds.position.x) * inv_cell), 0, cols - 1);
	const int y0 = std::clamp((int)std::floor((miny - bounds.position.y) * inv_cell), 0, rows - 1);
	const int y1 = std::clamp((int)std::floor((maxy - bounds.position.y) * inv_cell), 0, rows - 1);
	double best = 2.0;
	int best_w = -1;
	for (int cy = y0; cy <= y1; cy++) {
		for (int cx = x0; cx <= x1; cx++) {
			const size_t c = (size_t)cy * cols + cx;
			if (c + 1 >= w_cell_start.size()) {
				continue;
			}
			for (int k = w_cell_start[c]; k < w_cell_start[c + 1]; k++) {
				const int w = w_cell_walls[k];
				const double lx = wall_lo_x[w] - r, hx = wall_hi_x[w] + r;
				const double ly = wall_lo_y[w] - r, hy = wall_hi_y[w] + r;
				if (maxx < lx || minx > hx || maxy < ly || miny > hy) {
					continue;
				}
				double t_min = 0.0, t_max = 1.0;
				bool ok = true;
				if (std::fabs(dx) < 1e-9) {
					ok = !(sx < lx || sx > hx);
				} else {
					double a = (lx - sx) / dx, b = (hx - sx) / dx;
					if (a > b) {
						std::swap(a, b);
					}
					t_min = std::max(t_min, a);
					t_max = std::min(t_max, b);
					ok = t_min <= t_max;
				}
				if (ok) {
					if (std::fabs(dy) < 1e-9) {
						ok = !(sy < ly || sy > hy);
					} else {
						double a = (ly - sy) / dy, b = (hy - sy) / dy;
						if (a > b) {
							std::swap(a, b);
						}
						t_min = std::max(t_min, a);
						t_max = std::min(t_max, b);
						ok = t_min <= t_max;
					}
				}
				if (ok && (t_min < best || (t_min == best && w < best_w))) {
					best = t_min;
					best_w = w;
				}
			}
		}
	}
	if (best > 1.0 || best_w < 0) {
		return out;
	}
	out.t = best;
	out.wall = best_w;
	const float fr = (float)r;
	box_normal((float)sx, (float)sy, (float)dx, (float)dy, wall_lo_x[best_w] - fr, wall_lo_y[best_w] - fr, wall_hi_x[best_w] + fr,
			wall_hi_y[best_w] + fr, out.nx, out.ny);
	return out;
}

double NativeBulletSim::wall_first_hit(double sx, double sy, double dx, double dy, double r) const {
	return query_wall(sx, sy, dx, dy, r).t;
}

// ---------------------------------------------------------------------------
// bullets
// ---------------------------------------------------------------------------

int64_t NativeBulletSim::spawn(const Vector2 &p_position, const Vector2 &p_velocity, float p_angle, float p_lifetime,
		float p_radius, float p_damage, int p_hit_mask, const Color &p_color, float p_acceleration, float p_turn_rate,
		int p_pierce, bool p_collide_world, int p_owner_layer, int p_source_flags, int p_seq, int p_behavior,
		float p_param_a, float p_param_b) {
	const bool finite = std::isfinite(p_position.x) && std::isfinite(p_position.y) && std::isfinite(p_velocity.x)
			&& std::isfinite(p_velocity.y) && std::isfinite(p_radius) && std::isfinite(p_lifetime)
			&& std::isfinite(p_damage) && std::isfinite(p_acceleration) && std::isfinite(p_turn_rate)
			&& std::isfinite(p_param_a) && std::isfinite(p_param_b) && !std::isinf(p_angle);
	if (!finite) {
		// Same rule as BulletPool.spawn: a non-finite shot is refused. Not a capacity drop.
		return -1;
	}
	const int owner_slot = owner_slot_of(p_owner_layer);
	const int total = count + external_count;
	const int limit = (owner_slot == OWNER_ENEMY) ? logical_cap : other_limit;
	// `count >= capacity` is the physical backstop. With a shared cap at or below
	// capacity it only trips when this store itself has no slot left.
	if (total >= limit || count >= capacity) {
		note_drop(owner_slot, total >= logical_cap || count >= capacity);
		return -1;
	}
	const int i = count++;
	spawned_total++;
	owner_counts[owner_slot]++;
	const uint32_t h = (uint32_t)free_handles[--free_count];
	slot_of_handle[h] = i;
	handle_of_slot[i] = h;
	px[i] = qx[i] = p_position.x;
	py[i] = qy[i] = p_position.y;
	vx[i] = p_velocity.x;
	vy[i] = p_velocity.y;
	if (std::isnan(p_angle)) {
		const float speed = std::sqrt(p_velocity.x * p_velocity.x + p_velocity.y * p_velocity.y);
		rx[i] = speed > 0.0f ? p_velocity.x / speed : 1.0f;
		ry[i] = speed > 0.0f ? p_velocity.y / speed : 0.0f;
	} else {
		rx[i] = std::cos(p_angle);
		ry[i] = std::sin(p_angle);
	}
	radius[i] = p_radius;
	age[i] = 0.0f;
	lifetime[i] = p_lifetime;
	accel[i] = p_acceleration;
	turn[i] = p_turn_rate;
	damage[i] = p_damage;
	col[4 * i] = p_color.r;
	col[4 * i + 1] = p_color.g;
	col[4 * i + 2] = p_color.b;
	col[4 * i + 3] = p_color.a;
	hit_mask[i] = p_hit_mask;
	pierce[i] = p_pierce;
	owner_layer[i] = p_owner_layer;
	seq[i] = p_seq;
	behavior[i] = p_behavior;
	param_a[i] = p_param_a;
	param_b[i] = p_param_b;
	collide_world[i] = p_collide_world ? 1 : 0;
	source_flags[i] = (uint8_t)p_source_flags;
	reflect_count[i] = 0;
	wall_clip[i] = 1.0f;
	wall_suppress[i] = 0;
	wall_report[i] = 0;
	return_wall_pending[i] = 0;
	clear_hit_memory(i);
	dead[i] = 0;
	if (p_radius > max_radius) {
		max_radius = p_radius;
	}
	return ID_FLAG | ((int64_t)generation[h] << 32) | (int64_t)h;
}

bool NativeBulletSim::id_valid(int64_t p_id, uint32_t &r_handle) const {
	if (p_id <= 0 || (p_id & ID_FLAG) == 0) {
		return false;
	}
	const uint32_t h = (uint32_t)(p_id & 0xFFFFFFFFll);
	const uint32_t g = (uint32_t)((p_id >> 32) & GENERATION_MASK);
	if ((int)h >= capacity || generation[h] != g || slot_of_handle[h] < 0) {
		return false;
	}
	r_handle = h;
	return true;
}

int NativeBulletSim::slot_of(int64_t p_id) const {
	uint32_t h;
	return id_valid(p_id, h) ? slot_of_handle[h] : -1;
}

bool NativeBulletSim::is_alive(int64_t p_id) const {
	const int s = slot_of(p_id);
	return s >= 0 && dead[s] == 0;
}

int64_t NativeBulletSim::id_of(int p_slot) const {
	ERR_FAIL_INDEX_V(p_slot, count, -1);
	const uint32_t h = handle_of_slot[p_slot];
	return ID_FLAG | ((int64_t)generation[h] << 32) | (int64_t)h;
}

bool NativeBulletSim::kill(int64_t p_id) {
	const int s = slot_of(p_id);
	if (s < 0 || dead[s] != 0) {
		return false;
	}
	mark_dead(s, REASON_MANUAL);
	return true;
}

int NativeBulletSim::count_with_behavior(int p_behavior) const {
	int n = 0;
	for (int i = 0; i < count; i++) {
		if (dead[i] == 0 && behavior[i] == p_behavior) {
			n++;
		}
	}
	return n;
}

Dictionary NativeBulletSim::gather_batch(int p_behavior) const {
	int n = 0;
	for (int i = 0; i < count; i++) {
		if (dead[i] == 0 && behavior[i] == p_behavior) {
			n++;
		}
	}
	PackedInt64Array ids;
	PackedInt32Array owners;
	PackedFloat32Array pxa, pya, vxa, vya, agea, paa, pba;
	ids.resize(n);
	owners.resize(n);
	pxa.resize(n);
	pya.resize(n);
	vxa.resize(n);
	vya.resize(n);
	agea.resize(n);
	paa.resize(n);
	pba.resize(n);
	int w = 0;
	for (int i = 0; i < count; i++) {
		if (dead[i] != 0 || behavior[i] != p_behavior) {
			continue;
		}
		ids[w] = id_of(i);
		owners[w] = owner_layer[i];
		pxa[w] = px[i];
		pya[w] = py[i];
		vxa[w] = vx[i];
		vya[w] = vy[i];
		agea[w] = age[i];
		paa[w] = param_a[i];
		pba[w] = param_b[i];
		w++;
	}
	Dictionary d;
	d["n"] = n;
	d["id"] = ids;
	d["owner"] = owners;
	d["px"] = pxa;
	d["py"] = pya;
	d["vx"] = vxa;
	d["vy"] = vya;
	d["age"] = agea;
	d["pa"] = paa;
	d["pb"] = pba;
	return d;
}

static void clamp_speed(float &x, float &y, float cap) {
	if (!(cap > 0.0f) || !std::isfinite(x) || !std::isfinite(y)) {
		return;
	}
	const float ax = std::fabs(x);
	const float ay = std::fabs(y);
	const float m = ax > ay ? ax : ay;
	if (!(m > 0.0f)) {
		return;
	}
	// A component past ~1e19 squares to infinity in float32, so the length is
	// taken after scaling by the largest component (same as BulletLimits.clamp_velocity).
	// The old path divided by m and then treated the unit vector as the final
	// velocity, so vx=vy=3e38 became about (1, 1) and skipped the cap.
	float sx = x;
	float sy = y;
	if (m > 1.0e18f) {
		sx = x / m;
		sy = y / m;
	}
	const float sp = std::sqrt(sx * sx + sy * sy);
	const float length = (m > 1.0e18f) ? sp * m : sp;
	if (!(length > cap) || !(sp > 0.0f) || !std::isfinite(sp)) {
		return;
	}
	const float k = cap / sp;
	x = sx * k;
	y = sy * k;
}

// Same test as BulletLimits.exceeds: length_squared in double, so a float32
// component near 1e30 does not overflow the compare the way a float square would.
static bool speed_exceeds(float x, float y, float cap) {
	const double dx = (double)x;
	const double dy = (double)y;
	const double cap2 = (double)cap * (double)cap;
	return !(dx * dx + dy * dy <= cap2);
}

// Match BulletManager.BATCH_WARN_*. Integers only: the message is built in GDScript
// when the warning will actually be printed.
static const int BATCH_WARN_VELOCITY = 1;
static const int BATCH_WARN_SPEED = 2;
static const int BATCH_WARN_PA = 3;
static const int BATCH_WARN_PB = 4;

static void push_batch_warn(PackedInt32Array &rows, PackedInt32Array &codes, int row, int code) {
	rows.push_back(row);
	codes.push_back(code);
}

static Dictionary batch_report(int vel_nf, int pa_nf, int pb_nf, const PackedFloat32Array &clamp_vx, const PackedFloat32Array &clamp_vy,
		const PackedInt32Array &warn_row, const PackedInt32Array &warn_code) {
	Dictionary d;
	d["killed"] = vel_nf + pa_nf + pb_nf;
	d["vel_nonfinite"] = vel_nf;
	d["pa_nonfinite"] = pa_nf;
	d["pb_nonfinite"] = pb_nf;
	d["clamp_vx"] = clamp_vx;
	d["clamp_vy"] = clamp_vy;
	// Offending rows in the order the pool would warn, alongside the totals.
	d["warn_row"] = warn_row;
	d["warn_code"] = warn_code;
	return d;
}

Dictionary NativeBulletSim::apply_batch(const PackedInt64Array &p_ids, const PackedFloat32Array &p_vx, const PackedFloat32Array &p_vy,
		const PackedFloat32Array &p_pa, const PackedFloat32Array &p_pb) {
	int n = (int)p_ids.size();
	n = std::min(n, (int)p_vx.size());
	n = std::min(n, (int)p_vy.size());
	n = std::min(n, (int)p_pa.size());
	n = std::min(n, (int)p_pb.size());
	PackedFloat32Array clamp_vx;
	PackedFloat32Array clamp_vy;
	PackedInt32Array warn_row;
	PackedInt32Array warn_code;
	if (n <= 0) {
		return batch_report(0, 0, 0, clamp_vx, clamp_vy, warn_row, warn_code);
	}
	const int64_t *ids = p_ids.ptr();
	const float *wvx = p_vx.ptr();
	const float *wvy = p_vy.ptr();
	const float *wpa = p_pa.ptr();
	const float *wpb = p_pb.ptr();
	int vel_nf = 0;
	int pa_nf = 0;
	int pb_nf = 0;
	for (int i = 0; i < n; i++) {
		const int s = slot_of(ids[i]);
		// slot_of fails when the generation changed, so a reused slot is not written.
		if (s < 0 || dead[s] != 0) {
			continue;
		}
		float nvx = wvx[i];
		float nvy = wvy[i];
		const float npa = wpa[i];
		const float npb = wpb[i];
		// NaN != NaN, matching the GDScript dirty check before set_velocity / sanitize.
		const bool vel_dirty = nvx != vx[s] || nvy != vy[s];
		const bool pa_dirty = npa != param_a[s];
		const bool pb_dirty = npb != param_b[s];
		if (vel_dirty && (!std::isfinite(nvx) || !std::isfinite(nvy))) {
			vx[s] = 0.0f;
			vy[s] = 0.0f;
			mark_dead(s, REASON_INVALID);
			invalid_total++;
			vel_nf++;
			// set_velocity kills and returns before pa/pb are written.
			push_batch_warn(warn_row, warn_code, i, BATCH_WARN_VELOCITY);
			continue;
		}
		if (vel_dirty && speed_exceeds(nvx, nvy, max_speed)) {
			clamp_vx.push_back(nvx);
			clamp_vy.push_back(nvy);
			push_batch_warn(warn_row, warn_code, i, BATCH_WARN_SPEED);
		}
		if ((pa_dirty && !std::isfinite(npa)) || (pb_dirty && !std::isfinite(npb))) {
			vx[s] = 0.0f;
			vy[s] = 0.0f;
			mark_dead(s, REASON_INVALID);
			invalid_total++;
			// sanitize names the first non-finite field, so a bad pa hides pb.
			if (pa_dirty && !std::isfinite(npa)) {
				pa_nf++;
				push_batch_warn(warn_row, warn_code, i, BATCH_WARN_PA);
			} else {
				pb_nf++;
				push_batch_warn(warn_row, warn_code, i, BATCH_WARN_PB);
			}
			continue;
		}
		if (std::isfinite(nvx) && std::isfinite(nvy)) {
			clamp_speed(nvx, nvy, max_speed);
			vx[s] = nvx;
			vy[s] = nvy;
		}
		if (std::isfinite(npa)) {
			param_a[s] = npa;
		}
		if (std::isfinite(npb)) {
			param_b[s] = npb;
		}
	}
	return batch_report(vel_nf, pa_nf, pb_nf, clamp_vx, clamp_vy, warn_row, warn_code);
}

bool NativeBulletSim::teleport_id(int64_t p_id, float p_x, float p_y) {
	const int s = slot_of(p_id);
	if (s < 0 || dead[s] != 0) {
		return false;
	}
	if (!std::isfinite(p_x) || !std::isfinite(p_y)) {
		vx[s] = 0.0f;
		vy[s] = 0.0f;
		mark_dead(s, REASON_INVALID);
		invalid_total++;
		return false;
	}
	px[s] = p_x;
	py[s] = p_y;
	qx[s] = p_x;
	qy[s] = p_y;
	return true;
}

void NativeBulletSim::mark_dead(int slot, int reason) {
	if (dead[slot] != 0) {
		return;
	}
	dead[slot] = (uint8_t)(reason + 1);
	pending[pending_count++] = slot;
}

void NativeBulletSim::remove_at(int i) {
	const int last = count - 1;
	const int reason = dead[i] - 1;
	if (reason >= 0 && reason < REASON_COUNT) {
		despawn_counts[reason]++;
	}
	if (wall_report[i] != 0) {
		wall_reports.push_back(WallReport{ id_of(i), wall_nx[i], wall_ny[i] });
	}
	if (record_events && reason >= 0) {
		const bool wall = reason == REASON_WALL && wall_report[i] != 0;
		despawn_log.push_back(DespawnEvent{ lifetime[i], reason, wall ? wall_nx[i] : 0.0f, wall ? wall_ny[i] : 0.0f });
	}
	owner_counts[owner_slot_of(owner_layer[i])]--;
	if (retire_order.is_valid()) {
		retire_order.call(seq[i]);
	}
	const uint32_t released = handle_of_slot[i];
	generation[released] = (generation[released] + 1) & GENERATION_MASK;
	if (generation[released] == 0) {
		generation[released] = 1;
	}
	slot_of_handle[released] = -1;
	free_handles[free_count++] = (int32_t)released;
	if (i != last) {
		const uint32_t moved = handle_of_slot[last];
		handle_of_slot[i] = moved;
		slot_of_handle[moved] = i;
		px[i] = px[last];
		py[i] = py[last];
		qx[i] = qx[last];
		qy[i] = qy[last];
		vx[i] = vx[last];
		vy[i] = vy[last];
		rx[i] = rx[last];
		ry[i] = ry[last];
		radius[i] = radius[last];
		age[i] = age[last];
		lifetime[i] = lifetime[last];
		accel[i] = accel[last];
		turn[i] = turn[last];
		damage[i] = damage[last];
		col[4 * i] = col[4 * last];
		col[4 * i + 1] = col[4 * last + 1];
		col[4 * i + 2] = col[4 * last + 2];
		col[4 * i + 3] = col[4 * last + 3];
		hit_mask[i] = hit_mask[last];
		pierce[i] = pierce[last];
		owner_layer[i] = owner_layer[last];
		seq[i] = seq[last];
		behavior[i] = behavior[last];
		param_a[i] = param_a[last];
		param_b[i] = param_b[last];
		collide_world[i] = collide_world[last];
		source_flags[i] = source_flags[last];
		reflect_count[i] = reflect_count[last];
		wall_clip[i] = wall_clip[last];
		wall_nx[i] = wall_nx[last];
		wall_ny[i] = wall_ny[last];
		wall_suppress[i] = wall_suppress[last];
		wall_report[i] = wall_report[last];
		return_wall_pending[i] = return_wall_pending[last];
		copy_hit_memory(last, i);
		dead[i] = dead[last];
	} else {
		dead[i] = 0;
	}
	dead[last] = 0;
	count = last;
}

// Removes every bullet marked dead. Visits slots in marking order; if the
// bullet swapped into a slot is itself dead (it carries its flag) the slot is
// removed again. A slot already truncated away was the last bullet.
void NativeBulletSim::compact() {
	for (int k = 0; k < pending_count; k++) {
		int s = pending[k];
		while (s < count && dead[s] != 0) {
			remove_at(s);
		}
	}
	pending_count = 0;
}

void NativeBulletSim::clear() {
	for (int s = 0; s < count; s++) {
		const uint32_t h = handle_of_slot[s];
		generation[h] = (generation[h] + 1) & GENERATION_MASK;
		if (generation[h] == 0) {
			generation[h] = 1;
		}
	}
	std::fill(slot_of_handle.begin(), slot_of_handle.end(), -1);
	for (int k = 0; k < capacity; k++) {
		free_handles[k] = capacity - 1 - k;
	}
	free_count = capacity;
	std::fill(dead.begin(), dead.end(), 0);
	owner_counts[0] = owner_counts[1] = owner_counts[2] = 0;
	count = 0;
	pending_count = 0;
	wall_reports.clear();
	zone_events.clear();
	return_events.clear();
}

void NativeBulletSim::claim_from_bounds(int slot, int reason) {
	if (dead[slot] == (uint8_t)(REASON_BOUNDS + 1)) {
		dead[slot] = (uint8_t)(reason + 1);
	}
}

void NativeBulletSim::clear_hit_memory(int slot) {
	hit_mem_count[slot] = 0;
	hit_mem_head[slot] = 0;
}

void NativeBulletSim::remember_target(int slot, uint64_t target_id) {
	const int n = hit_mem_count[slot];
	uint64_t *base = &hit_mem[(size_t)slot * HIT_MEMORY];
	for (int k = 0; k < n; k++) {
		if (base[k] == target_id) {
			return;
		}
	}
	if (n < HIT_MEMORY) {
		base[n] = target_id;
		hit_mem_count[slot] = (uint8_t)(n + 1);
		return;
	}
	const int head = hit_mem_head[slot];
	base[head] = target_id;
	hit_mem_head[slot] = (uint8_t)((head + 1) % HIT_MEMORY);
}

bool NativeBulletSim::is_remembered(int slot, uint64_t target_id) const {
	const int n = hit_mem_count[slot];
	if (n == 0) {
		return false;
	}
	const uint64_t *base = &hit_mem[(size_t)slot * HIT_MEMORY];
	for (int k = 0; k < n; k++) {
		if (base[k] == target_id) {
			return true;
		}
	}
	return false;
}

void NativeBulletSim::copy_hit_memory(int src, int dst) {
	hit_mem_count[dst] = hit_mem_count[src];
	hit_mem_head[dst] = hit_mem_head[src];
	if (hit_mem_count[src] == 0) {
		return;
	}
	std::copy_n(&hit_mem[(size_t)src * HIT_MEMORY], HIT_MEMORY, &hit_mem[(size_t)dst * HIT_MEMORY]);
}

// ---------------------------------------------------------------------------
// the tick
// ---------------------------------------------------------------------------

void NativeBulletSim::begin_step() {
	hit_events.clear();
	wall_slots.clear();
	zone_events.clear();
	return_events.clear();
	wall_reports.clear();
	if (record_events) {
		hit_log.clear();
		despawn_log.clear();
	}
	last_hit_count = 0;
	last_wall_hit_count = 0;
	if (walls_dirty) {
		rebuild_walls();
	}
	rebuild_hash();
}

NativeBulletSim::IntegratedMotion NativeBulletSim::compute_motion(int i, double delta, float fdelta, float min_x, float min_y, float max_x, float max_y) const {
	IntegratedMotion m;
	m.vx = vx[i];
	m.vy = vy[i];
	m.rx = rx[i];
	m.ry = ry[i];
	m.nx = px[i];
	m.ny = py[i];
	const double a = (double)age[i] + delta;
	if (a >= (double)lifetime[i]) {
		m.expired = true;
		return m;
	}
	float vxi = m.vx, vyi = m.vy;
	const float tr = turn[i], ac = accel[i];
	if (tr != 0.0f || ac != 0.0f) {
		if (tr != 0.0f) {
			const float ang = (float)((double)tr * delta);
			const float s = std::sin(ang), c = std::cos(ang);
			const float nvx = vxi * c - vyi * s, nvy = vxi * s + vyi * c;
			vxi = nvx;
			vyi = nvy;
			const float nrx = m.rx * c - m.ry * s, nry = m.rx * s + m.ry * c;
			m.rx = nrx;
			m.ry = nry;
		}
		if (ac != 0.0f) {
			const float speed = std::sqrt(vxi * vxi + vyi * vyi);
			if (speed > 0.0f) {
				// Same as BulletPool.advance: acceleration cannot push past the ceiling.
				double grown = std::max((double)speed + (double)ac * delta, 0.0);
				if (max_speed > 0.0f) {
					grown = std::min(grown, (double)max_speed);
				}
				const float k = (float)(grown / (double)speed);
				vxi *= k;
				vyi *= k;
			}
		}
	}
	m.vx = vxi;
	m.vy = vyi;
	m.nx = px[i] + vxi * fdelta;
	m.ny = py[i] + vyi * fdelta;
	m.out_of_bounds = m.nx < min_x || m.nx > max_x || m.ny < min_y || m.ny > max_y;
	return m;
}

bool NativeBulletSim::integrate_one(int i, double delta, float fdelta, float min_x, float min_y, float max_x, float max_y) {
	if (dead[i] != 0) {
		return false;
	}
	qx[i] = px[i];
	qy[i] = py[i];
	wall_clip[i] = 1.0f;
	wall_suppress[i] = 0;
	wall_report[i] = 0;
	return_wall_pending[i] = 0;
	wall_nx[i] = 0.0f;
	wall_ny[i] = 0.0f;
	const IntegratedMotion m = compute_motion(i, delta, fdelta, min_x, min_y, max_x, max_y);
	age[i] = (float)((double)age[i] + delta);
	if (m.expired) {
		mark_dead(i, REASON_LIFETIME);
		return false;
	}
	vx[i] = m.vx;
	vy[i] = m.vy;
	rx[i] = m.rx;
	ry[i] = m.ry;
	// A bullet that leaves the world still tests its final segment. Marked
	// now, before collision, so a later hit or wall can relabel it (the
	// pool's claim_from_bounds). The stored position stays the end of the
	// path until a killing hit snaps it.
	if (m.out_of_bounds) {
		mark_dead(i, REASON_BOUNDS);
	}
	px[i] = m.nx;
	py[i] = m.ny;
	return true;
}

void NativeBulletSim::collide_one(int i, bool have_walls, bool have_targets) {
	const float old_x = qx[i], old_y = qy[i];
	float nx = px[i], ny = py[i];
	const float vxi = vx[i], vyi = vy[i];
	const double r = radius[i];
	// Walls first: the bullet is clipped to the impact point. The kill is
	// applied in deliver_hits(), after hurtboxes, so a target in front of
	// the wall wins the reason. The segment is the integrated path, not the
	// velocity: a script reflect may already have reversed vx/vy.
	if (have_walls && collide_world[i]) {
		const WallContact hit = query_wall(old_x, old_y, (double)nx - old_x, (double)ny - old_y, r);
		if (hit.t >= 0.0) {
			wall_slots.push_back(i);
			wall_clip[i] = (float)hit.t;
			wall_nx[i] = hit.nx;
			wall_ny[i] = hit.ny;
			wall_report[i] = 1;
			nx = (float)(old_x + ((double)nx - old_x) * hit.t);
			ny = (float)(old_y + ((double)ny - old_y) * hit.t);
		}
	}

	// Hurtboxes. Pierce consumption and the killing snap wait until
	// deliver_hits(), which skips a target that was turned off this tick.
	// A short non-piercing path uses the pool's endpoint test (impact at
	// the end position). Anything else is swept, up to pierce + 1 hits.
	const int mask = hit_mask[i];
	if (have_targets && mask != 0) {
		const double dx = (double)nx - old_x;
		const double dy = (double)ny - old_y;
		const double reach = (double)min_target_radius + r;
		const bool short_path = pierce[i] == 0 && (dx * dx + dy * dy) <= reach * reach;
		if (short_path) {
			int ti = -1;
			if (point_hit(nx, ny, r, mask, i, ti)) {
				hit_events.push_back(HitEvent{ targets[ti].id, id_of(i), nx, ny, vxi, vyi, damage[i], source_flags[i], seq[i], 1.0f });
			}
		} else {
			double sx = old_x, sy = old_y;
			int left = pierce[i];
			excl_buf.clear();
			for (;;) {
				double t;
				const int ti = sweep_targets(sx, sy, (double)nx - sx, (double)ny - sy, r, mask, i, excl_buf.data(),
						(int)excl_buf.size(), t);
				if (ti < 0) {
					break;
				}
				const double ix = sx + ((double)nx - sx) * t;
				const double iy = sy + ((double)ny - sy) * t;
				float path_t = 0.0f;
				const float sdx = nx - old_x;
				const float sdy = ny - old_y;
				if (std::fabs(sdx) >= std::fabs(sdy)) {
					path_t = std::fabs(sdx) > 1e-8f ? (float)((ix - old_x) / (double)sdx) : 0.0f;
				} else {
					path_t = std::fabs(sdy) > 1e-8f ? (float)((iy - old_y) / (double)sdy) : 0.0f;
				}
				hit_events.push_back(HitEvent{ targets[ti].id, id_of(i), (float)ix, (float)iy, vxi, vyi, damage[i],
						source_flags[i], seq[i], path_t });
				if (left > 0) {
					left--;
					excl_buf.push_back(ti);
					sx = ix;
					sy = iy;
					continue;
				}
				break;
			}
		}
	}

	if (zone_count > 0 && owner_layer[i] != 0 && (dead[i] == 0 || dead[i] == REASON_BOUNDS + 1)) {
		sweep_zones_for(i, old_x, old_y, nx - old_x, ny - old_y, (float)r, owner_layer[i]);
	}

	px[i] = nx;
	py[i] = ny;
}

int NativeBulletSim::step(double delta) {
	begin_step();
	const float min_x = bounds.position.x, min_y = bounds.position.y;
	const float max_x = bounds.position.x + bounds.size.x, max_y = bounds.position.y + bounds.size.y;
	const bool have_walls = !wall_lo_x.empty();
	const bool have_targets = target_count > 0;
	const float fdelta = (float)delta;
	for (int i = 0; i < count; i++) {
		if (!integrate_one(i, delta, fdelta, min_x, min_y, max_x, max_y)) {
			continue;
		}
		collide_one(i, have_walls, have_targets);
	}
	last_hit_count = (int)hit_events.size();
	last_wall_hit_count = (int)wall_slots.size();
	return last_hit_count;
}

void NativeBulletSim::integrate(double delta) {
	begin_step();
	const float min_x = bounds.position.x, min_y = bounds.position.y;
	const float max_x = bounds.position.x + bounds.size.x, max_y = bounds.position.y + bounds.size.y;
	const float fdelta = (float)delta;
	const int n = count;
	if ((int)collide_mark.size() < n) {
		collide_mark.resize(n);
	}
	for (int i = 0; i < n; i++) {
		collide_mark[i] = integrate_one(i, delta, fdelta, min_x, min_y, max_x, max_y) ? 1 : 0;
	}
}

int NativeBulletSim::collide() {
	// integrate() hashed the targets it saw. A hook between the two can move a
	// hurtbox or change the list; rebuild so the sweep matches set_targets().
	rebuild_hash();
	const bool have_walls = !wall_lo_x.empty();
	const bool have_targets = target_count > 0;
	const int n = std::min(count, (int)collide_mark.size());
	for (int i = 0; i < n; i++) {
		if (collide_mark[i] == 0) {
			continue;
		}
		// A batch kill between integrate and collide must not still sweep.
		// Bounds deaths stay: that segment is tested, same as the one-pass step.
		if (dead[i] != 0 && dead[i] != (uint8_t)(REASON_BOUNDS + 1)) {
			continue;
		}
		collide_one(i, have_walls, have_targets);
	}
	last_hit_count = (int)hit_events.size();
	last_wall_hit_count = (int)wall_slots.size();
	return last_hit_count;
}

bool NativeBulletSim::integrate_would_die(int64_t p_id, double p_delta) const {
	const int s = slot_of(p_id);
	if (s < 0 || dead[s] != 0) {
		return true;
	}
	const float min_x = bounds.position.x, min_y = bounds.position.y;
	const float max_x = bounds.position.x + bounds.size.x, max_y = bounds.position.y + bounds.size.y;
	const IntegratedMotion m = compute_motion(s, p_delta, (float)p_delta, min_x, min_y, max_x, max_y);
	return m.expired || m.out_of_bounds;
}

int NativeBulletSim::get_reflect_count_of(int64_t p_id) const {
	const int s = slot_of(p_id);
	if (s < 0 || dead[s] != 0) {
		return -1;
	}
	return reflect_count[s];
}

void NativeBulletSim::commit_hit(const HitEvent &h) {
	const int s = slot_of(h.bullet_id);
	if (s < 0) {
		return;
	}
	const int dead_now = dead[s];
	if (dead_now != 0 && dead_now != REASON_BOUNDS + 1) {
		return;
	}
	Object *target = ObjectDB::get_instance(h.target_id);
	if (target == nullptr) {
		return;
	}
	const Variant active = target->get("active");
	if (active.get_type() == Variant::BOOL && !(bool)active) {
		return;
	}
	// Absorb arc (Hurtbox.Response): one property read per hit. Only a non-NORMAL
	// hurtbox is asked Hurtbox.absorbs(), the same method BulletManager._apply_hit
	// calls for GD bullets, so both backends decide identically. An absorbed bullet
	// stops at the contact point and despawns as ABSORBED, piercing or not, with
	// no damage and no hit event.
	const Variant response = target->get("response");
	if (response.get_type() == Variant::INT && (int64_t)response != 0) {
		const Vector2 contact(h.x, h.y);
		const Variant absorbed = target->call("absorbs", contact);
		if (absorbed.get_type() == Variant::BOOL && (bool)absorbed) {
			px[s] = h.x;
			py[s] = h.y;
			if (return_wall_pending[s] != 0) {
				return_wall_pending[s] = 0;
				wall_report[s] = 0;
				wall_nx[s] = 0.0f;
				wall_ny[s] = 0.0f;
			}
			target->call("receive_absorb", contact, Vector2(h.vx, h.vy), h.bullet_id, h.flags);
			mark_dead(s, REASON_ABSORBED);
			claim_from_bounds(s, REASON_ABSORBED);
			return;
		}
	}
	const bool piercing = pierce[s] > 0;
	if (!piercing) {
		px[s] = h.x;
		py[s] = h.y;
		// A killing hit on the return leg never reaches the wall behind it.
		if (return_wall_pending[s] != 0) {
			return_wall_pending[s] = 0;
			wall_report[s] = 0;
			wall_nx[s] = 0.0f;
			wall_ny[s] = 0.0f;
		}
	}
	target->call("receive_hit", h.damage, Vector2(h.x, h.y), Vector2(h.vx, h.vy), h.bullet_id, h.flags);
	if (record_events) {
		hit_log.push_back(h);
	}
	if (piercing) {
		remember_target(s, h.target_id);
		pierce[s] -= 1;
	} else {
		mark_dead(s, REASON_HIT);
		claim_from_bounds(s, REASON_HIT);
	}
}

void NativeBulletSim::commit_pending_hit(int p_index) {
	if (p_index < 0 || p_index >= (int)hit_events.size()) {
		return;
	}
	commit_hit(hit_events[(size_t)p_index]);
}

PackedInt32Array NativeBulletSim::get_pending_hit_seqs() const {
	PackedInt32Array out;
	out.resize((int)hit_events.size());
	for (int i = 0; i < (int)hit_events.size(); i++) {
		out[i] = hit_events[(size_t)i].seq;
	}
	return out;
}

PackedFloat32Array NativeBulletSim::get_pending_hit_t() const {
	PackedFloat32Array out;
	out.resize((int)hit_events.size());
	for (int i = 0; i < (int)hit_events.size(); i++) {
		out[i] = hit_events[(size_t)i].path_t;
	}
	return out;
}

int NativeBulletSim::find_seq(int p_seq) const {
	for (int i = 0; i < count; i++) {
		if (seq[i] == p_seq) {
			return i;
		}
	}
	return -1;
}

void NativeBulletSim::set_seq_at(int p_slot, int p_seq) {
	if (p_slot >= 0 && p_slot < count) {
		seq[p_slot] = p_seq;
	}
}

void NativeBulletSim::deliver_hits() {
	for (const HitEvent &h : hit_events) {
		commit_hit(h);
	}
	finish_delivery();
}

void NativeBulletSim::finish_delivery() {
	// Bullets are still in place until compact, so a handler may spawn without
	// pulling a later hit's slot out from under it. Hits left uncommitted are
	// skipped: the manager delivers them itself, in global seq order.
	for (int s : wall_slots) {
		if (s < 0 || s >= count || wall_suppress[s] != 0) {
			continue;
		}
		if (dead[s] != 0 && dead[s] != REASON_BOUNDS + 1) {
			continue;
		}
		mark_dead(s, REASON_WALL);
		claim_from_bounds(s, REASON_WALL);
	}
	compact();
	// One delivery per step. A second call must not re-apply these slots after
	// compact has moved other bullets into them.
	hit_events.clear();
	wall_slots.clear();
}

// ---------------------------------------------------------------------------
// rendering
// ---------------------------------------------------------------------------

int NativeBulletSim::upload(const RID &p_multimesh, int p_allocated, bool p_interpolate, float p_stretch) {
	const int n = std::min(count, p_allocated);
	const int64_t floats = (int64_t)p_allocated * FLOATS_PER_INSTANCE;
	// Two sets used alternately: the RenderingServer keeps a reference to the
	// buffers it was last given, so the set not handed over last tick is
	// uniquely owned and is written without a copy-on-write.
	buf_set ^= 1;
	PackedFloat32Array &cur = cur_buf[buf_set];
	PackedFloat32Array &prev = prev_buf[buf_set];
	if (cur.size() != floats) {
		cur.resize(floats);
	}
	if (p_interpolate && prev.size() != floats) {
		prev.resize(floats);
	}
	float *c = cur.ptrw();
	float *p = p_interpolate ? prev.ptrw() : nullptr;
	const float length_scale = 2.0f * p_stretch;
	for (int i = 0; i < n; i++) {
		float *o = c + (size_t)i * FLOATS_PER_INSTANCE;
		const float r = radius[i];
		const float sx = r * length_scale, sy = r * 2.0f;
		const float m00 = rx[i] * sx, m01 = -ry[i] * sy, m10 = ry[i] * sx, m11 = rx[i] * sy;
		o[0] = m00;
		o[1] = m01;
		o[2] = 0.0f;
		o[3] = px[i];
		o[4] = m10;
		o[5] = m11;
		o[6] = 0.0f;
		o[7] = py[i];
		o[8] = col[4 * i];
		o[9] = col[4 * i + 1];
		o[10] = col[4 * i + 2];
		o[11] = col[4 * i + 3];
		if (p != nullptr) {
			float *q = p + (size_t)i * FLOATS_PER_INSTANCE;
			q[0] = m00;
			q[1] = m01;
			q[2] = 0.0f;
			q[3] = qx[i];
			q[4] = m10;
			q[5] = m11;
			q[6] = 0.0f;
			q[7] = qy[i];
			q[8] = o[8];
			q[9] = o[9];
			q[10] = o[10];
			q[11] = o[11];
		}
	}
	RenderingServer *rs = RenderingServer::get_singleton();
	if (p_interpolate) {
		rs->multimesh_set_buffer_interpolated(p_multimesh, cur, prev);
	} else {
		rs->multimesh_set_buffer(p_multimesh, cur);
	}
	return n;
}

// ---------------------------------------------------------------------------
// inspection
// ---------------------------------------------------------------------------

PackedInt32Array NativeBulletSim::get_despawn_counts() const {
	PackedInt32Array out;
	out.resize(REASON_COUNT);
	for (int k = 0; k < REASON_COUNT; k++) {
		out[k] = (int32_t)despawn_counts[k];
	}
	return out;
}

Dictionary NativeBulletSim::snapshot() const {
	PackedVector2Array pos, prev, vel;
	PackedFloat32Array ages, lifes, rads;
	PackedInt32Array pierces, masks, owners, reflects, seqs;
	PackedInt64Array ids;
	pos.resize(count);
	prev.resize(count);
	vel.resize(count);
	ages.resize(count);
	lifes.resize(count);
	rads.resize(count);
	pierces.resize(count);
	masks.resize(count);
	owners.resize(count);
	reflects.resize(count);
	seqs.resize(count);
	ids.resize(count);
	for (int i = 0; i < count; i++) {
		pos[i] = Vector2(px[i], py[i]);
		prev[i] = Vector2(qx[i], qy[i]);
		vel[i] = Vector2(vx[i], vy[i]);
		ages[i] = age[i];
		lifes[i] = lifetime[i];
		rads[i] = radius[i];
		pierces[i] = pierce[i];
		masks[i] = hit_mask[i];
		owners[i] = owner_layer[i];
		reflects[i] = reflect_count[i];
		seqs[i] = seq[i];
		ids[i] = id_of(i);
	}
	Dictionary d;
	d["pos"] = pos;
	d["prev_pos"] = prev;
	d["vel"] = vel;
	d["age"] = ages;
	d["lifetime"] = lifes;
	d["radius"] = rads;
	d["pierce"] = pierces;
	d["hit_mask"] = masks;
	d["owner"] = owners;
	d["reflect_count"] = reflects;
	d["seq"] = seqs;
	d["id"] = ids;
	return d;
}

int NativeBulletSim::get_owner_count(int p_layer) const {
	return (int)owner_counts[owner_slot_of(p_layer)];
}

PackedInt32Array NativeBulletSim::get_owner_counts() const {
	PackedInt32Array out;
	out.resize(3);
	for (int k = 0; k < 3; k++) {
		out[k] = (int32_t)owner_counts[k];
	}
	return out;
}

PackedInt32Array NativeBulletSim::get_dropped_by_owner() const {
	PackedInt32Array out;
	out.resize(3);
	for (int k = 0; k < 3; k++) {
		out[k] = (int32_t)dropped_by_owner[k];
	}
	return out;
}

PackedInt32Array NativeBulletSim::get_dropped_by_limit() const {
	PackedInt32Array out;
	out.resize(2);
	out[0] = (int32_t)dropped_by_limit[0];
	out[1] = (int32_t)dropped_by_limit[1];
	return out;
}

Dictionary NativeBulletSim::bullet_row(int i) const {
	Dictionary row;
	row["pos"] = Vector2(px[i], py[i]);
	row["prev"] = Vector2(qx[i], qy[i]);
	row["vel"] = Vector2(vx[i], vy[i]);
	row["rot"] = Vector2(rx[i], ry[i]);
	row["radius"] = radius[i];
	row["age"] = age[i];
	row["lifetime"] = lifetime[i];
	row["accel"] = accel[i];
	row["turn"] = turn[i];
	row["damage"] = damage[i];
	row["param_a"] = param_a[i];
	row["param_b"] = param_b[i];
	row["behavior"] = behavior[i];
	row["color"] = Color(col[4 * i], col[4 * i + 1], col[4 * i + 2], col[4 * i + 3]);
	row["hit_mask"] = hit_mask[i];
	row["pierce"] = pierce[i];
	row["owner"] = owner_layer[i];
	row["collide"] = collide_world[i] != 0;
	row["flags"] = (int)source_flags[i];
	row["seq"] = seq[i];
	row["reflect_count"] = (int)reflect_count[i];
	PackedInt64Array mem;
	const int n = hit_mem_count[i];
	mem.resize(n);
	const uint64_t *base = &hit_mem[(size_t)i * HIT_MEMORY];
	for (int k = 0; k < n; k++) {
		mem[k] = (int64_t)base[k];
	}
	row["hit_mem"] = mem;
	row["hit_head"] = (int)hit_mem_head[i];
	return row;
}

Array NativeBulletSim::export_states() const {
	Array out;
	for (int i = 0; i < count; i++) {
		out.push_back(bullet_row(i));
	}
	return out;
}

Array NativeBulletSim::extract_behavior(int p_behavior) {
	// A kill only marks the slot. Compacting first keeps that bullet from being
	// swapped into another slot's pending index and then never removed.
	compact();
	Array out;
	int i = 0;
	while (i < count) {
		if (dead[i] != 0 || behavior[i] != p_behavior) {
			i++;
			continue;
		}
		out.push_back(bullet_row(i));
		// remove_at retires the seq and frees the id. No despawn reason: dead is 0.
		remove_at(i);
	}
	return out;
}

Vector2 NativeBulletSim::get_velocity_of(int64_t p_id) const {
	const int s = slot_of(p_id);
	if (s < 0) {
		return Vector2();
	}
	return Vector2(vx[s], vy[s]);
}

float NativeBulletSim::get_param_a_of(int64_t p_id) const {
	const int s = slot_of(p_id);
	return s < 0 ? 0.0f : param_a[s];
}

float NativeBulletSim::get_param_b_of(int64_t p_id) const {
	const int s = slot_of(p_id);
	return s < 0 ? 0.0f : param_b[s];
}

Array NativeBulletSim::get_last_despawns() const {
	Array out;
	for (const DespawnEvent &e : despawn_log) {
		Dictionary d;
		d["lifetime"] = e.lifetime;
		d["reason"] = e.reason;
		d["normal"] = Vector2(e.nx, e.ny);
		out.push_back(d);
	}
	return out;
}

Array NativeBulletSim::get_last_hits() const {
	Array out;
	for (const HitEvent &h : hit_log) {
		Dictionary d;
		d["target_id"] = (int64_t)h.target_id;
		d["bullet_id"] = h.bullet_id;
		d["position"] = Vector2(h.x, h.y);
		d["velocity"] = Vector2(h.vx, h.vy);
		d["damage"] = h.damage;
		out.push_back(d);
	}
	return out;
}

// ---------------------------------------------------------------------------
// reflectors and wall normals
// ---------------------------------------------------------------------------

void NativeBulletSim::resize_zone_grid() {
	const size_t cells = (size_t)cols * (size_t)rows;
	z_heads.assign(cells, -1);
	z_occupied.assign(cells, 0);
	z_touched.clear();
	z_entry_count = 0;
}

void NativeBulletSim::set_zones(const PackedVector2Array &p_pos, const PackedFloat32Array &p_radius, const PackedInt32Array &p_owners, int p_count) {
	p_count = std::min(p_count, (int)std::min({ p_pos.size(), p_radius.size(), p_owners.size() }));
	zone_count = std::max(p_count, 0);
	zones.resize((size_t)zone_count);
	const Vector2 *pp = p_pos.ptr();
	const float *pr = p_radius.ptr();
	const int32_t *po = p_owners.ptr();
	for (int k = 0; k < zone_count; k++) {
		zones[k] = Zone{ pp[k].x, pp[k].y, pr[k], po[k] };
	}
	rebuild_zones();
}

void NativeBulletSim::rebuild_zones() {
	if ((int)z_heads.size() != cols * rows) {
		resize_zone_grid();
	}
	for (int32_t cell : z_touched) {
		z_heads[cell] = -1;
		z_occupied[cell] = 0;
	}
	z_touched.clear();
	z_entry_count = 0;
	const float margin = max_radius;
	for (int id = 0; id < zone_count; id++) {
		const Zone &z = zones[id];
		const float reach = z.r + margin;
		int x0 = std::clamp((int)std::floor((z.x - reach - bounds.position.x) * inv_cell), 0, cols - 1);
		int x1 = std::clamp((int)std::floor((z.x + reach - bounds.position.x) * inv_cell), 0, cols - 1);
		int y0 = std::clamp((int)std::floor((z.y - reach - bounds.position.y) * inv_cell), 0, rows - 1);
		int y1 = std::clamp((int)std::floor((z.y + reach - bounds.position.y) * inv_cell), 0, rows - 1);
		for (int cy = y0; cy <= y1; cy++) {
			for (int cx = x0; cx <= x1; cx++) {
				const int cell = cy * cols + cx;
				if ((size_t)z_entry_count >= z_entry_target.size()) {
					size_t ns = std::max<size_t>(256, z_entry_target.size() * 2);
					z_entry_target.resize(ns);
					z_entry_next.resize(ns);
				}
				const int e = z_entry_count++;
				z_entry_target[e] = id;
				z_entry_next[e] = z_heads[cell];
				if (!z_occupied[cell]) {
					z_occupied[cell] = 1;
					z_touched.push_back(cell);
				}
				z_heads[cell] = e;
			}
		}
	}
}

static int cell_trunc(float v, int hi) {
	int i = (int)v;
	if (i < 0) {
		i = 0;
	}
	if (i > hi) {
		i = hi;
	}
	return i;
}

void NativeBulletSim::sweep_zones_for(int slot, float sx, float sy, float dx, float dy, float br, int mask) {
	if (zone_count <= 0 || mask == 0) {
		return;
	}
	const float ox = bounds.position.x, oy = bounds.position.y;
	const float inv = inv_cell;
	const float fx0 = (sx - ox) * inv;
	const float fy0 = (sy - oy) * inv;
	const float dfx = dx * inv;
	const float dfy = dy * inv;
	float tc0 = 0.0f, tc1 = 1.0f;
	if (dfx == 0.0f) {
		if (fx0 < 0.0f || fx0 >= (float)cols) {
			return;
		}
	} else {
		const float ta = -fx0 / dfx;
		const float tb = ((float)cols - fx0) / dfx;
		tc0 = std::max(tc0, std::min(ta, tb));
		tc1 = std::min(tc1, std::max(ta, tb));
	}
	if (dfy == 0.0f) {
		if (fy0 < 0.0f || fy0 >= (float)rows) {
			return;
		}
	} else {
		const float tya = -fy0 / dfy;
		const float tyb = ((float)rows - fy0) / dfy;
		tc0 = std::max(tc0, std::min(tya, tyb));
		tc1 = std::min(tc1, std::max(tya, tyb));
	}
	if (tc0 > tc1) {
		return;
	}
	const int max_hits = std::min(zone_count, MAX_ZONE_HITS);
	int excl[MAX_ZONE_HITS];
	int excl_n = 0;
	float t_min = 0.0f;
	const float a = dx * dx + dy * dy;
	for (int n = 0; n < max_hits; n++) {
		const float t_begin = std::max(tc0, t_min);
		if (t_begin > tc1) {
			return;
		}
		const float px0 = fx0 + dfx * t_begin;
		const float py0 = fy0 + dfy * t_begin;
		int cx = cell_trunc(px0, cols - 1);
		int cy = cell_trunc(py0, rows - 1);
		const int ex = cell_trunc(fx0 + dfx * tc1, cols - 1);
		const int ey = cell_trunc(fy0 + dfy * tc1, rows - 1);
		const int step_x = dx > 0.0f ? 1 : -1;
		const int step_y = dy > 0.0f ? 1 : -1;
		float tmax_x = std::numeric_limits<float>::infinity();
		float tmax_y = std::numeric_limits<float>::infinity();
		float tdelta_x = std::numeric_limits<float>::infinity();
		float tdelta_y = std::numeric_limits<float>::infinity();
		if (dfx != 0.0f) {
			tdelta_x = std::fabs(1.0f / dfx);
			tmax_x = t_begin + ((float)(cx + (step_x > 0 ? 1 : 0)) - px0) / dfx;
		}
		if (dfy != 0.0f) {
			tdelta_y = std::fabs(1.0f / dfy);
			tmax_y = t_begin + ((float)(cy + (step_y > 0 ? 1 : 0)) - py0) / dfy;
		}
		const int steps = std::abs(ex - cx) + std::abs(ey - cy) + 1;
		float best_t = 2.0f;
		int best = -1;
		for (int stp = 0; stp < steps; stp++) {
			const int cell = cy * cols + cx;
			if (cell >= 0 && cell < (int)z_occupied.size() && z_occupied[cell]) {
				for (int e = z_heads[cell]; e != -1; e = z_entry_next[e]) {
					const int zi = z_entry_target[e];
					const Zone &z = zones[zi];
					if ((z.layer & mask) == 0) {
						continue;
					}
					bool skip = false;
					for (int k = 0; k < excl_n; k++) {
						if (excl[k] == zi) {
							skip = true;
							break;
						}
					}
					if (skip) {
						continue;
					}
					const float rr = z.r + br;
					const float fx = sx - z.x;
					const float fy = sy - z.y;
					const float c = fx * fx + fy * fy - rr * rr;
					float hit = -1.0f;
					if (a > 0.0f) {
						const float b = fx * dx + fy * dy;
						const float disc = b * b - a * c;
						if (disc >= 0.0f) {
							const float root = std::sqrt(disc);
							if ((-b + root) / a >= t_min) {
								hit = std::max((-b - root) / a, t_min);
							}
						}
					} else if (c <= 0.0f) {
						hit = 0.0f;
					}
					if (hit >= 0.0f && hit <= 1.0f && hit < best_t) {
						best_t = hit;
						best = zi;
					}
				}
			}
			if (best != -1 && std::min(tmax_x, tmax_y) >= best_t) {
				break;
			}
			if (cx == ex || (cy != ey && tmax_y < tmax_x)) {
				cy += step_y;
				tmax_y += tdelta_y;
			} else {
				cx += step_x;
				tmax_x += tdelta_x;
			}
		}
		if (best < 0) {
			return;
		}
		zone_events.push_back(ZoneEvent{ slot, best, best_t, seq[slot] });
		excl[excl_n++] = best;
		t_min = best_t;
		if (t_min >= 1.0f) {
			return;
		}
	}
}

PackedInt32Array NativeBulletSim::get_zone_hit_slots() const {
	PackedInt32Array out;
	out.resize((int)zone_events.size());
	for (int i = 0; i < (int)zone_events.size(); i++) {
		out[i] = zone_events[(size_t)i].slot;
	}
	return out;
}

PackedInt32Array NativeBulletSim::get_zone_hit_zones() const {
	PackedInt32Array out;
	out.resize((int)zone_events.size());
	for (int i = 0; i < (int)zone_events.size(); i++) {
		out[i] = zone_events[(size_t)i].zone;
	}
	return out;
}

PackedFloat32Array NativeBulletSim::get_zone_hit_t() const {
	PackedFloat32Array out;
	out.resize((int)zone_events.size());
	for (int i = 0; i < (int)zone_events.size(); i++) {
		out[i] = zone_events[(size_t)i].t;
	}
	return out;
}

PackedInt32Array NativeBulletSim::get_zone_hit_seqs() const {
	PackedInt32Array out;
	out.resize((int)zone_events.size());
	for (int i = 0; i < (int)zone_events.size(); i++) {
		out[i] = zone_events[(size_t)i].seq;
	}
	return out;
}

Vector2 NativeBulletSim::get_position_at(int p_slot) const {
	if (p_slot < 0 || p_slot >= count) {
		return Vector2();
	}
	return Vector2(px[p_slot], py[p_slot]);
}

Vector2 NativeBulletSim::get_previous_at(int p_slot) const {
	if (p_slot < 0 || p_slot >= count) {
		return Vector2();
	}
	return Vector2(qx[p_slot], qy[p_slot]);
}

Vector2 NativeBulletSim::get_velocity_at(int p_slot) const {
	if (p_slot < 0 || p_slot >= count) {
		return Vector2();
	}
	return Vector2(vx[p_slot], vy[p_slot]);
}

int NativeBulletSim::get_owner_at(int p_slot) const {
	if (p_slot < 0 || p_slot >= count) {
		return 0;
	}
	return owner_layer[p_slot];
}

int NativeBulletSim::get_reflect_count_at(int p_slot) const {
	if (p_slot < 0 || p_slot >= count) {
		return 0;
	}
	return reflect_count[p_slot];
}

float NativeBulletSim::get_wall_clip_at(int p_slot) const {
	if (p_slot < 0 || p_slot >= count) {
		return 1.0f;
	}
	return wall_clip[p_slot];
}

bool NativeBulletSim::is_slot_alive(int p_slot) const {
	return p_slot >= 0 && p_slot < count && dead[p_slot] == 0;
}

bool NativeBulletSim::apply_reflect(int p_slot, int p_new_owner, int p_new_mask, const Color &p_color, float p_new_damage, bool p_keep_script, int p_limit, const Vector2 &p_heading, float p_speed, const Vector2 &p_impact) {
	if (!is_slot_alive(p_slot)) {
		return false;
	}
	if (p_new_owner != LAYER_PLAYER && p_new_owner != LAYER_ENEMY) {
		return false;
	}
	if (p_limit > 0 && reflect_count[p_slot] >= p_limit) {
		return false;
	}
	if (!std::isfinite(p_heading.x) || !std::isfinite(p_heading.y) || !std::isfinite(p_speed) || !std::isfinite(p_impact.x) || !std::isfinite(p_impact.y) || !std::isfinite(p_new_damage)) {
		return false;
	}
	const int old_owner = owner_slot_of(owner_layer[p_slot]);
	const int new_owner = owner_slot_of(p_new_owner);
	if (old_owner != new_owner) {
		owner_counts[old_owner]--;
		owner_counts[new_owner]++;
	}
	owner_layer[p_slot] = p_new_owner;
	if (reflect_count[p_slot] < 255) {
		reflect_count[p_slot]++;
	}
	hit_mask[p_slot] = p_new_mask;
	col[4 * p_slot] = p_color.r;
	col[4 * p_slot + 1] = p_color.g;
	col[4 * p_slot + 2] = p_color.b;
	col[4 * p_slot + 3] = p_color.a;
	clear_hit_memory(p_slot);
	if (p_new_damage >= 0.0f) {
		damage[p_slot] = p_new_damage;
	}
	if (!p_keep_script) {
		source_flags[p_slot] = 0;
	}
	float hx = p_heading.x;
	float hy = p_heading.y;
	float vxn = hx * p_speed;
	float vyn = hy * p_speed;
	if (max_speed > 0.0f) {
		const float sp2 = vxn * vxn + vyn * vyn;
		const float cap = max_speed * max_speed;
		if (sp2 > cap && sp2 > 0.0f) {
			const float k = max_speed / std::sqrt(sp2);
			vxn *= k;
			vyn *= k;
		}
	}
	vx[p_slot] = vxn;
	vy[p_slot] = vyn;
	if (p_speed > 0.0f) {
		rx[p_slot] = hx;
		ry[p_slot] = hy;
	}
	px[p_slot] = p_impact.x;
	py[p_slot] = p_impact.y;
	qx[p_slot] = p_impact.x;
	qy[p_slot] = p_impact.y;
	return true;
}

bool NativeBulletSim::apply_script_reflect(int64_t p_id, int p_new_owner, int p_new_mask, const Color &p_color, float p_new_damage, bool p_keep_script, bool p_reverse, int p_limit) {
	const int s = slot_of(p_id);
	if (s < 0 || dead[s] != 0) {
		return false;
	}
	if (p_new_owner != LAYER_PLAYER && p_new_owner != LAYER_ENEMY) {
		return false;
	}
	if (p_limit > 0 && reflect_count[s] >= p_limit) {
		return false;
	}
	const int old_owner = owner_slot_of(owner_layer[s]);
	const int new_slot = owner_slot_of(p_new_owner);
	if (old_owner != new_slot) {
		owner_counts[old_owner]--;
		owner_counts[new_slot]++;
	}
	owner_layer[s] = p_new_owner;
	if (reflect_count[s] < 255) {
		reflect_count[s]++;
	}
	hit_mask[s] = p_new_mask;
	col[4 * s] = p_color.r;
	col[4 * s + 1] = p_color.g;
	col[4 * s + 2] = p_color.b;
	col[4 * s + 3] = p_color.a;
	clear_hit_memory(s);
	if (p_new_damage >= 0.0f) {
		damage[s] = p_new_damage;
	}
	if (!p_keep_script) {
		// Match BulletPool.reflect: the bullet leaves its behaviour before this
		// tick's batch gather, so a column write cannot replace the new velocity.
		source_flags[s] = 0;
		behavior[s] = 0;
		param_a[s] = 0.0f;
		param_b[s] = 0.0f;
	}
	if (p_reverse) {
		vx[s] = -vx[s];
		vy[s] = -vy[s];
		rx[s] = -rx[s];
		ry[s] = -ry[s];
	}
	return true;
}

void NativeBulletSim::cancel_outbound_wall(int p_slot) {
	if (p_slot < 0 || p_slot >= count) {
		return;
	}
	wall_suppress[p_slot] = 1;
	wall_report[p_slot] = 0;
	wall_nx[p_slot] = 0.0f;
	wall_ny[p_slot] = 0.0f;
}

void NativeBulletSim::begin_return(int p_slot, double p_delta, float p_reflected_t) {
	if (!is_slot_alive(p_slot)) {
		return;
	}
	const float start_x = px[p_slot];
	const float start_y = py[p_slot];
	const float remain = (1.0f - p_reflected_t) * (float)p_delta;
	float ddx = vx[p_slot] * remain;
	float ddy = vy[p_slot] * remain;
	return_wall_pending[p_slot] = 0;
	if (collide_world[p_slot] != 0 && (ddx != 0.0f || ddy != 0.0f)) {
		const WallContact hit = query_wall(start_x, start_y, ddx, ddy, radius[p_slot]);
		if (hit.t >= 0.0) {
			ddx *= (float)hit.t;
			ddy *= (float)hit.t;
			wall_nx[p_slot] = hit.nx;
			wall_ny[p_slot] = hit.ny;
			wall_report[p_slot] = 1;
			return_wall_pending[p_slot] = 1;
		}
	}
	qx[p_slot] = start_x;
	qy[p_slot] = start_y;
	px[p_slot] = start_x + ddx;
	py[p_slot] = start_y + ddy;
	const int mask = hit_mask[p_slot];
	if (target_count <= 0 || mask == 0) {
		return;
	}
	const int max_hits = pierce[p_slot] + 1;
	excl_buf.clear();
	double sx = start_x, sy = start_y;
	const double end_x = px[p_slot], end_y = py[p_slot];
	for (int left = max_hits; left > 0; left--) {
		double t = 0.0;
		const int ti = sweep_targets(sx, sy, end_x - sx, end_y - sy, radius[p_slot], mask, p_slot, excl_buf.data(), (int)excl_buf.size(), t);
		if (ti < 0) {
			break;
		}
		const double ix = sx + (end_x - sx) * t;
		const double iy = sy + (end_y - sy) * t;
		return_events.push_back(HitEvent{ targets[ti].id, id_of(p_slot), (float)ix, (float)iy, vx[p_slot], vy[p_slot], damage[p_slot], source_flags[p_slot], seq[p_slot], (float)t });
		excl_buf.push_back(ti);
		sx = ix;
		sy = iy;
		if (t >= 1.0) {
			break;
		}
	}
}

void NativeBulletSim::commit_return_hit(int p_index) {
	if (p_index < 0 || p_index >= (int)return_events.size()) {
		return;
	}
	commit_hit(return_events[(size_t)p_index]);
}

void NativeBulletSim::finish_return(int p_slot) {
	if (p_slot < 0 || p_slot >= count || return_wall_pending[p_slot] == 0) {
		return;
	}
	return_wall_pending[p_slot] = 0;
	if (dead[p_slot] != 0) {
		wall_report[p_slot] = 0;
		wall_nx[p_slot] = 0.0f;
		wall_ny[p_slot] = 0.0f;
		return;
	}
	mark_dead(p_slot, REASON_WALL);
	claim_from_bounds(p_slot, REASON_WALL);
}

Vector2 NativeBulletSim::get_wall_normal(int64_t p_id) const {
	const int s = slot_of(p_id);
	if (s >= 0 && wall_report[s] != 0) {
		return Vector2(wall_nx[s], wall_ny[s]);
	}
	for (const WallReport &r : wall_reports) {
		if (r.id == p_id) {
			return Vector2(r.nx, r.ny);
		}
	}
	return Vector2();
}

void NativeBulletSim::clear_wall_normals() {
	wall_reports.clear();
	for (int i = 0; i < count; i++) {
		wall_report[i] = 0;
	}
}

Vector2 NativeBulletSim::query_wall_normal(const Vector2 &p_start, const Vector2 &p_delta, float p_radius) {
	if (walls_dirty) {
		rebuild_walls();
	}
	const WallContact hit = query_wall(p_start.x, p_start.y, p_delta.x, p_delta.y, p_radius);
	if (hit.t < 0.0) {
		return Vector2();
	}
	return Vector2(hit.nx, hit.ny);
}

} // namespace scriptshot

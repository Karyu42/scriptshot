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
	ClassDB::bind_method(D_METHOD("configure", "capacity", "bounds", "cell_size"), &NativeBulletSim::configure);
	ClassDB::bind_method(D_METHOD("add_wall", "rect"), &NativeBulletSim::add_wall);
	ClassDB::bind_method(D_METHOD("clear_walls"), &NativeBulletSim::clear_walls);
	ClassDB::bind_method(D_METHOD("get_wall_count"), &NativeBulletSim::get_wall_count);
	ClassDB::bind_method(D_METHOD("set_targets", "pos", "radius", "layer", "ids", "count"), &NativeBulletSim::set_targets);
	ClassDB::bind_method(D_METHOD("step", "delta"), &NativeBulletSim::step);
	ClassDB::bind_method(D_METHOD("upload", "multimesh", "allocated", "interpolate", "stretch"), &NativeBulletSim::upload);
	ClassDB::bind_method(D_METHOD("spawn", "position", "velocity", "angle", "lifetime", "radius", "damage", "hit_mask", "color",
								"acceleration", "turn_rate", "pierce", "collide_world"),
			&NativeBulletSim::spawn);
	ClassDB::bind_method(D_METHOD("is_alive", "id"), &NativeBulletSim::is_alive);
	ClassDB::bind_method(D_METHOD("slot_of", "id"), &NativeBulletSim::slot_of);
	ClassDB::bind_method(D_METHOD("id_of", "slot"), &NativeBulletSim::id_of);
	ClassDB::bind_method(D_METHOD("kill", "id"), &NativeBulletSim::kill);
	ClassDB::bind_method(D_METHOD("clear"), &NativeBulletSim::clear);
	ClassDB::bind_method(D_METHOD("get_count"), &NativeBulletSim::get_count);
	ClassDB::bind_method(D_METHOD("get_capacity"), &NativeBulletSim::get_capacity);
	ClassDB::bind_method(D_METHOD("get_spawned_total"), &NativeBulletSim::get_spawned_total);
	ClassDB::bind_method(D_METHOD("get_dropped_total"), &NativeBulletSim::get_dropped_total);
	ClassDB::bind_method(D_METHOD("get_max_radius"), &NativeBulletSim::get_max_radius);
	ClassDB::bind_method(D_METHOD("get_last_hit_count"), &NativeBulletSim::get_last_hit_count);
	ClassDB::bind_method(D_METHOD("get_last_wall_hit_count"), &NativeBulletSim::get_last_wall_hit_count);
	ClassDB::bind_method(D_METHOD("get_despawn_counts"), &NativeBulletSim::get_despawn_counts);
	ClassDB::bind_method(D_METHOD("snapshot"), &NativeBulletSim::snapshot);
	ClassDB::bind_method(D_METHOD("set_record_events", "on"), &NativeBulletSim::set_record_events);
	ClassDB::bind_method(D_METHOD("get_last_hits"), &NativeBulletSim::get_last_hits);

	BIND_ENUM_CONSTANT(REASON_LIFETIME);
	BIND_ENUM_CONSTANT(REASON_BOUNDS);
	BIND_ENUM_CONSTANT(REASON_HIT);
	BIND_ENUM_CONSTANT(REASON_MANUAL);
	BIND_ENUM_CONSTANT(REASON_CLEARED);
	BIND_ENUM_CONSTANT(REASON_WALL);
}

// ---------------------------------------------------------------------------
// setup
// ---------------------------------------------------------------------------

void NativeBulletSim::configure(int p_capacity, const Rect2 &p_bounds, float p_cell_size) {
	ERR_FAIL_COND(p_capacity <= 0);
	ERR_FAIL_COND(p_cell_size <= 0.0f);
	capacity = p_capacity;
	count = 0;
	bounds = p_bounds;
	cell_size = p_cell_size;
	inv_cell = 1.0f / cell_size;
	cols = std::max(1, (int)std::ceil(bounds.size.x * inv_cell));
	rows = std::max(1, (int)std::ceil(bounds.size.y * inv_cell));
	const size_t n = (size_t)capacity;
	for (auto *v : { &px, &py, &qx, &qy, &vx, &vy, &rx, &ry, &radius, &age, &lifetime, &accel, &turn, &damage }) {
		v->assign(n, 0.0f);
	}
	col.assign(n * 4, 1.0f);
	hit_mask.assign(n, 0);
	pierce.assign(n, 0);
	collide_world.assign(n, 1);
	dead.assign(n, 0);
	last_hit.assign(n, 0);
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
	walls_dirty = true;
	hit_events.reserve(1024);
	for (int s = 0; s < 2; s++) {
		cur_buf[s].clear();
		prev_buf[s].clear();
	}
	spawned_total = dropped_total = 0;
	max_radius = 0.0f;
	for (auto &c : despawn_counts) {
		c = 0;
	}
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
	for (int k = 0; k < target_count; k++) {
		targets[k] = Target{ pp[k].x, pp[k].y, pr[k], pl[k], (uint64_t)pi[k] };
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
// and the target indices in `excl`). Returns the target index or -1 and sets r_t.
//
// Grid traversal visits the cells under the path in order of entry time and
// keeps going until the next cell is entered at or after the best hit so far,
// so a nearer target in a later cell is never missed (a bigger target found
// first in an earlier cell does not shadow it).
int NativeBulletSim::sweep_targets(double sx, double sy, double dx, double dy, double r, int mask, uint64_t last,
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
				if ((t.layer & mask) == 0 || t.id == last) {
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

// ---------------------------------------------------------------------------
// walls
// ---------------------------------------------------------------------------

// First t in [0, 1] at which the segment s + d*t enters any wall grown by `r`
// (0 if it starts inside one), or -1.0.
double NativeBulletSim::wall_first_hit(double sx, double sy, double dx, double dy, double r) const {
	const double ex = sx + dx, ey = sy + dy;
	const double minx = std::min(sx, ex) - r, maxx = std::max(sx, ex) + r;
	const double miny = std::min(sy, ey) - r, maxy = std::max(sy, ey) + r;
	const int x0 = std::clamp((int)std::floor((minx - bounds.position.x) * inv_cell), 0, cols - 1);
	const int x1 = std::clamp((int)std::floor((maxx - bounds.position.x) * inv_cell), 0, cols - 1);
	const int y0 = std::clamp((int)std::floor((miny - bounds.position.y) * inv_cell), 0, rows - 1);
	const int y1 = std::clamp((int)std::floor((maxy - bounds.position.y) * inv_cell), 0, rows - 1);
	double best = 2.0;
	for (int cy = y0; cy <= y1; cy++) {
		for (int cx = x0; cx <= x1; cx++) {
			const size_t c = (size_t)cy * cols + cx;
			for (int k = w_cell_start[c]; k < w_cell_start[c + 1]; k++) {
				const int w = w_cell_walls[k];
				const double lx = wall_lo_x[w] - r, hx = wall_hi_x[w] + r;
				const double ly = wall_lo_y[w] - r, hy = wall_hi_y[w] + r;
				// Cheap reject on the path's bounding box.
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
				if (ok && t_min < best) {
					best = t_min;
				}
			}
		}
	}
	return best <= 1.0 ? best : -1.0;
}

// ---------------------------------------------------------------------------
// bullets
// ---------------------------------------------------------------------------

int64_t NativeBulletSim::spawn(const Vector2 &p_position, const Vector2 &p_velocity, float p_angle, float p_lifetime,
		float p_radius, float p_damage, int p_hit_mask, const Color &p_color, float p_acceleration, float p_turn_rate,
		int p_pierce, bool p_collide_world) {
	if (count >= capacity) {
		dropped_total++;
		return -1;
	}
	const int i = count++;
	spawned_total++;
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
	collide_world[i] = p_collide_world ? 1 : 0;
	last_hit[i] = 0;
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

void NativeBulletSim::mark_dead(int slot, int reason) {
	if (dead[slot] != 0) {
		return;
	}
	dead[slot] = (uint8_t)(reason + 1);
	pending[pending_count++] = slot;
}

void NativeBulletSim::remove_at(int i) {
	const int last = count - 1;
	despawn_counts[dead[i] - 1]++;
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
		collide_world[i] = collide_world[last];
		last_hit[i] = last_hit[last];
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
	count = 0;
	pending_count = 0;
}

// ---------------------------------------------------------------------------
// the tick
// ---------------------------------------------------------------------------

int NativeBulletSim::step(double delta) {
	hit_events.clear();
	if (record_events) {
		hit_log.clear();
	}
	last_hit_count = 0;
	last_wall_hit_count = 0;
	if (walls_dirty) {
		rebuild_walls();
	}
	rebuild_hash();

	const float min_x = bounds.position.x, min_y = bounds.position.y;
	const float max_x = bounds.position.x + bounds.size.x, max_y = bounds.position.y + bounds.size.y;
	const bool have_walls = !wall_lo_x.empty();
	const bool have_targets = target_count > 0;
	const float fdelta = (float)delta;
	int32_t excl[64];

	for (int i = 0; i < count; i++) {
		if (dead[i] != 0) {
			continue;
		}
		const float old_x = px[i], old_y = py[i];
		qx[i] = old_x;
		qy[i] = old_y;
		const double a = (double)age[i] + delta;
		age[i] = (float)a;
		if (a >= (double)lifetime[i]) {
			mark_dead(i, REASON_LIFETIME);
			continue;
		}
		float vxi = vx[i], vyi = vy[i];
		const float tr = turn[i], ac = accel[i];
		if (tr != 0.0f || ac != 0.0f) {
			if (tr != 0.0f) {
				const float ang = (float)((double)tr * delta);
				const float s = std::sin(ang), c = std::cos(ang);
				const float nvx = vxi * c - vyi * s, nvy = vxi * s + vyi * c;
				vxi = nvx;
				vyi = nvy;
				const float nrx = rx[i] * c - ry[i] * s, nry = rx[i] * s + ry[i] * c;
				rx[i] = nrx;
				ry[i] = nry;
			}
			if (ac != 0.0f) {
				const float speed = std::sqrt(vxi * vxi + vyi * vyi);
				if (speed > 0.0f) {
					const float k = (float)(std::max((double)speed + (double)ac * delta, 0.0) / (double)speed);
					vxi *= k;
					vyi *= k;
				}
			}
			vx[i] = vxi;
			vy[i] = vyi;
		}
		float nx = old_x + vxi * fdelta, ny = old_y + vyi * fdelta;
		// A bullet that leaves the world still tests its final segment.
		const bool out_of_bounds = nx < min_x || nx > max_x || ny < min_y || ny > max_y;
		const double r = radius[i];

		// Walls first: the bullet is clipped to the impact point.
		bool wall_hit = false;
		if (have_walls && collide_world[i]) {
			const double t = wall_first_hit(old_x, old_y, (double)nx - old_x, (double)ny - old_y, r);
			if (t >= 0.0) {
				wall_hit = true;
				nx = (float)(old_x + ((double)nx - old_x) * t);
				ny = (float)(old_y + ((double)ny - old_y) * t);
			}
		}

		// Hurtboxes: swept, up to pierce + 1 hits along the remaining path.
		bool hit_dead = false;
		const int mask = hit_mask[i];
		if (have_targets && mask != 0) {
			double sx = old_x, sy = old_y;
			int excl_n = 0;
			for (;;) {
				double t;
				const int ti = sweep_targets(sx, sy, (double)nx - sx, (double)ny - sy, r, mask, last_hit[i], excl, excl_n, t);
				if (ti < 0) {
					break;
				}
				const double ix = sx + ((double)nx - sx) * t, iy = sy + ((double)ny - sy) * t;
				hit_events.push_back(HitEvent{ targets[ti].id, id_of(i), (float)ix, (float)iy, vxi, vyi, damage[i] });
				if (pierce[i] > 0) {
					pierce[i]--;
					last_hit[i] = targets[ti].id;
					if (excl_n < 64) {
						excl[excl_n++] = ti;
					}
					sx = (float)ix;
					sy = (float)iy;
					continue;
				}
				nx = (float)ix;
				ny = (float)iy;
				hit_dead = true;
				break;
			}
		}

		px[i] = nx;
		py[i] = ny;
		if (hit_dead) {
			mark_dead(i, REASON_HIT);
		} else if (wall_hit) {
			last_wall_hit_count++;
			mark_dead(i, REASON_WALL);
		} else if (out_of_bounds) {
			mark_dead(i, REASON_BOUNDS);
		}
	}
	if (hit_events.size() > 0) {
		last_hit_count = (int)hit_events.size();
	}
	compact();

	// Deliver hits after the loop: a handler may spawn bullets or free the target.
	for (const HitEvent &h : hit_events) {
		if (record_events) {
			hit_log.push_back(h);
		}
		Object *target = ObjectDB::get_instance(h.target_id);
		if (target != nullptr) {
			target->call("receive_hit", h.damage, Vector2(h.x, h.y), Vector2(h.vx, h.vy));
		}
	}
	return last_hit_count;
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
	out.resize(6);
	for (int k = 0; k < 6; k++) {
		out[k] = (int32_t)despawn_counts[k];
	}
	return out;
}

Dictionary NativeBulletSim::snapshot() const {
	PackedVector2Array pos, prev, vel;
	PackedFloat32Array ages, lifes, rads;
	PackedInt32Array pierces, masks;
	PackedInt64Array ids;
	pos.resize(count);
	prev.resize(count);
	vel.resize(count);
	ages.resize(count);
	lifes.resize(count);
	rads.resize(count);
	pierces.resize(count);
	masks.resize(count);
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
	d["id"] = ids;
	return d;
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

} // namespace scriptshot

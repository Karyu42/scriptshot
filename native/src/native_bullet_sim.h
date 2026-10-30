#pragma once
// NativeBulletSim: the plain-bullet simulation of Scriptshot in C++.
//
// Struct-of-arrays bullet storage with stable ids (handle + generation
// indirection), integration (acceleration, turn rate,
// lifetime, bounds), swept collision against the hurtbox spatial hash and the
// static wall grid, pierce re-sweeps, swap-remove compaction and the
// interpolated MultiMesh buffer fill. It has no knowledge of GDScript bullet
// hooks: BulletManager keeps bullets that have a BulletBehavior in the
// GDScript BulletPool and sends every plain bullet here.
//
// Semantics intentionally mirror src/bullets/*.gd (see docs/native.md).

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/packed_byte_array.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_int64_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/rect2.hpp>
#include <godot_cpp/variant/rid.hpp>
#include <godot_cpp/variant/variant.hpp>
#include <godot_cpp/variant/vector2.hpp>

#include <cstdint>
#include <vector>

namespace scriptshot {

class NativeBulletSim : public godot::RefCounted {
	GDCLASS(NativeBulletSim, godot::RefCounted)

public:
	// Same numbering as BulletPool.DespawnReason.
	enum DespawnReason {
		REASON_LIFETIME = 0,
		REASON_BOUNDS,
		REASON_HIT,
		REASON_MANUAL,
		REASON_CLEARED,
		REASON_WALL,
	};

	static constexpr int FLOATS_PER_INSTANCE = 12;
	// Native ids carry this bit so they never collide with BulletPool ids.
	static constexpr int64_t ID_FLAG = int64_t(1) << 62;
	static constexpr uint32_t GENERATION_MASK = 0x3FFFFFFFu;

	NativeBulletSim();

	// --- setup -----------------------------------------------------------
	void configure(int p_capacity, const godot::Rect2 &p_bounds, float p_cell_size);
	void add_wall(const godot::Rect2 &p_rect);
	void clear_walls();
	int get_wall_count() const { return (int)wall_lo_x.size(); }

	// --- per tick --------------------------------------------------------
	void set_targets(const godot::PackedVector2Array &p_pos, const godot::PackedFloat32Array &p_radius,
			const godot::PackedInt32Array &p_layer, const godot::PackedInt64Array &p_ids, int p_count);
	int step(double p_delta);
	// Writes the live bullets into the MultiMesh buffers and uploads them.
	// Returns the live count (use it as visible_instance_count).
	int upload(const godot::RID &p_multimesh, int p_allocated, bool p_interpolate, float p_stretch);

	// --- bullets ---------------------------------------------------------
	int64_t spawn(const godot::Vector2 &p_position, const godot::Vector2 &p_velocity, float p_angle, float p_lifetime,
			float p_radius, float p_damage, int p_hit_mask, const godot::Color &p_color, float p_acceleration,
			float p_turn_rate, int p_pierce, bool p_collide_world);
	bool is_alive(int64_t p_id) const;
	int slot_of(int64_t p_id) const;
	int64_t id_of(int p_slot) const;
	// Marks a bullet for removal (reason MANUAL); it disappears at the next step().
	bool kill(int64_t p_id);
	void clear();

	// --- inspection ------------------------------------------------------
	int get_count() const { return count; }
	int get_capacity() const { return capacity; }
	int64_t get_spawned_total() const { return spawned_total; }
	int64_t get_dropped_total() const { return dropped_total; }
	float get_max_radius() const { return max_radius; }
	int get_last_hit_count() const { return last_hit_count; }
	int get_last_wall_hit_count() const { return last_wall_hit_count; }
	godot::PackedInt32Array get_despawn_counts() const;
	godot::Dictionary snapshot() const;
	void set_record_events(bool p_on) { record_events = p_on; }
	godot::Array get_last_hits() const;

protected:
	static void _bind_methods();

private:
	struct HitEvent {
		uint64_t target_id;
		int64_t bullet_id;
		float x, y, vx, vy, damage;
	};

	// ---- bullet storage (dense [0, count)) ----
	int capacity = 0;
	int count = 0;
	std::vector<float> px, py, qx, qy, vx, vy, rx, ry;
	std::vector<float> radius, age, lifetime, accel, turn, damage;
	std::vector<float> col; // 4 per bullet
	std::vector<int32_t> hit_mask, pierce;
	std::vector<uint8_t> collide_world, dead;
	std::vector<uint64_t> last_hit;
	std::vector<uint32_t> handle_of_slot;
	std::vector<int32_t> pending;
	int pending_count = 0;

	// ---- handle indirection ----
	std::vector<int32_t> slot_of_handle;
	std::vector<uint32_t> generation;
	std::vector<int32_t> free_handles;
	int free_count = 0;

	int64_t spawned_total = 0;
	int64_t dropped_total = 0;
	float max_radius = 0.0f;
	int last_hit_count = 0;
	int last_wall_hit_count = 0;
	int64_t despawn_counts[6] = { 0, 0, 0, 0, 0, 0 };

	// ---- world ----
	godot::Rect2 bounds;
	float cell_size = 64.0f;
	float inv_cell = 1.0f / 64.0f;
	int cols = 1, rows = 1;

	// ---- hurtbox targets + spatial hash (rebuilt each step) ----
	struct Target {
		float x, y, r;
		int32_t layer;
		uint64_t id;
	};
	std::vector<Target> targets;
	int target_count = 0;
	std::vector<int32_t> t_heads;
	std::vector<uint8_t> t_occupied;
	std::vector<int32_t> t_touched;
	std::vector<int32_t> t_entry_next, t_entry_target;
	int t_entry_count = 0;

	// ---- walls (static; CSR cell lists rebuilt on change) ----
	std::vector<float> wall_lo_x, wall_lo_y, wall_hi_x, wall_hi_y;
	std::vector<int32_t> w_cell_start; // cols*rows + 1
	std::vector<int32_t> w_cell_walls;
	bool walls_dirty = true;

	// ---- events ----
	std::vector<HitEvent> hit_events;
	bool record_events = false;
	std::vector<HitEvent> hit_log;

	// ---- render buffers: two alternating sets, see upload() ----
	godot::PackedFloat32Array cur_buf[2];
	godot::PackedFloat32Array prev_buf[2];
	int buf_set = 0;

	void rebuild_hash();
	void rebuild_walls();
	void mark_dead(int slot, int reason);
	void remove_at(int slot);
	void compact();
	bool id_valid(int64_t p_id, uint32_t &r_handle) const;
	void reset_handles();

	double wall_first_hit(double sx, double sy, double dx, double dy, double r) const;
	int sweep_targets(double sx, double sy, double dx, double dy, double r, int mask, uint64_t last,
			const int32_t *excl, int excl_n, double &r_t) const;
};

} // namespace scriptshot

VARIANT_ENUM_CAST(scriptshot::NativeBulletSim::DespawnReason);

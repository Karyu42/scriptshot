#pragma once
// NativeBulletSim: the hook-free bullet simulation of Scriptshot in C++.
//
// Struct-of-arrays bullet storage with stable ids (handle + generation
// indirection), integration (acceleration, turn rate, lifetime, bounds),
// swept collision against the hurtbox spatial hash and the static wall grid,
// pierce re-sweeps, the same hit-memory ring as BulletPool, the same
// saturation limits, swap-remove compaction and the interpolated MultiMesh
// buffer fill. It has no knowledge of GDScript bullet hooks: BulletManager
// keeps bullets with a per-bullet hook in the GDScript BulletPool.
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
#include <godot_cpp/variant/callable.hpp>
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
		REASON_INVALID,
	};

	static constexpr int FLOATS_PER_INSTANCE = 12;
	// Native ids carry this bit so they never collide with BulletPool ids.
	static constexpr int64_t ID_FLAG = int64_t(1) << 62;
	static constexpr uint32_t GENERATION_MASK = 0x3FFFFFFFu;
	// Same ring as BulletPool.HIT_MEMORY. Only a pierce hit that lands is recorded.
	static constexpr int HIT_MEMORY = 8;
	// Same slots as BulletPool.OWNER_*. Player wins when both faction bits are set.
	static constexpr int OWNER_NONE = 0;
	static constexpr int OWNER_PLAYER = 1;
	static constexpr int OWNER_ENEMY = 2;
	static constexpr int LAYER_PLAYER = 1;
	static constexpr int LAYER_ENEMY = 2;
	// Same indexes as BulletPool.DropLimit.
	static constexpr int DROP_LOGICAL_CAP = 0;
	static constexpr int DROP_ENEMY_RESERVE = 1;

	NativeBulletSim();

	// --- setup -----------------------------------------------------------
	// p_max_speed is BulletLimits.MAX_SPEED, passed in so the ceiling lives in one place.
	void configure(int p_capacity, const godot::Rect2 &p_bounds, float p_cell_size, float p_max_speed);
	// Logical cap and enemy reserve, clamped the same way as BulletPool.set_limits.
	// Until this is called, the store allows `capacity` bullets with no reserve
	// (a bare BulletPool does the same).
	void set_limits(int p_cap, int p_reserve);
	// Recentres the collision grids on a new rectangle without moving bullets.
	// The next step re-buckets walls. Used when the camera window slides.
	void set_bounds(const godot::Rect2 &p_bounds);
	// Bullets living in the GDScript pool, added to `count` for the saturation
	// check so the two stores share one cap. BulletManager sets this before spawn.
	void set_external_count(int p_count);
	void add_wall(const godot::Rect2 &p_rect);
	void clear_walls();
	int get_wall_count() const { return (int)wall_lo_x.size(); }

	// --- per tick --------------------------------------------------------
	void set_targets(const godot::PackedVector2Array &p_pos, const godot::PackedFloat32Array &p_radius,
			const godot::PackedInt32Array &p_layer, const godot::PackedInt64Array &p_ids, int p_count);
	int step(double p_delta);
	// Move only. collide() runs the sweeps, so a script reflect queued during
	// on_update can land after this tick's travel and before collision.
	void integrate(double p_delta);
	int collide();
	// True when advance would already have killed this id (lifetime or bounds),
	// which is the state BulletPool.reflect sees from on_update.
	bool integrate_would_die(int64_t p_id, double p_delta) const;
	int get_reflect_count_of(int64_t p_id) const;
	// BulletPool.reflect for a stable id. Does not move the bullet. A stale
	// generation (the slot was reused) returns false and writes nothing.
	bool apply_script_reflect(int64_t p_id, int p_new_owner, int p_new_mask, const godot::Color &p_color,
			float p_new_damage, bool p_keep_script, bool p_reverse, int p_limit);
	// Sends the hits queued by the last step() to Hurtbox.receive_hit. Separate from
	// step() so BulletManager can deliver them after the GDScript collision pass:
	// a callback that spawns is not swept until the next tick, same as on_hit.
	void deliver_hits();
	// Hit candidates queued by the last step(), in store iteration order.
	// commit_pending_hit applies one (inactive targets consume nothing).
	// finish_delivery applies walls and compacts. Uncommitted hits are skipped.
	int get_pending_hit_count() const { return (int)hit_events.size(); }
	godot::PackedInt32Array get_pending_hit_seqs() const;
	godot::PackedFloat32Array get_pending_hit_t() const;
	void commit_pending_hit(int p_index);
	void finish_delivery();
	int find_seq(int p_seq) const;
	void set_seq_at(int p_slot, int p_seq);
	// Full state of every live bullet, for moving them into the GDScript pool.
	godot::Array export_states() const;
	// Removes every live bullet of `p_behavior` without a despawn reason and
	// returns the same rows as export_states. Used when a batch-only weapon
	// gains a per-bullet hook and those bullets must move to the GDScript pool.
	godot::Array extract_behavior(int p_behavior);
	godot::Vector2 get_velocity_of(int64_t p_id) const;
	float get_param_a_of(int64_t p_id) const;
	float get_param_b_of(int64_t p_id) const;
	godot::Dictionary bullet_row(int p_slot) const;

	// Reflector zones for this tick (circle, owner mask). Empty disables the
	// zone sweep. BulletManager passes the active Reflector list, in registry
	// order, after on_update and before step().
	void set_zones(const godot::PackedVector2Array &p_pos, const godot::PackedFloat32Array &p_radius,
			const godot::PackedInt32Array &p_owners, int p_count);
	int get_zone_hit_count() const { return (int)zone_events.size(); }
	godot::PackedInt32Array get_zone_hit_slots() const;
	godot::PackedInt32Array get_zone_hit_zones() const;
	godot::PackedFloat32Array get_zone_hit_t() const;
	godot::PackedInt32Array get_zone_hit_seqs() const;

	// Bullet fields the reflector rule reads. Slot is the dense index.
	godot::Vector2 get_position_at(int p_slot) const;
	godot::Vector2 get_previous_at(int p_slot) const;
	godot::Vector2 get_velocity_at(int p_slot) const;
	int get_owner_at(int p_slot) const;
	int get_reflect_count_at(int p_slot) const;
	float get_wall_clip_at(int p_slot) const;
	bool is_slot_alive(int p_slot) const;

	// Applies BulletPool.reflect + the post-reflect velocity and teleport.
	// `p_new_damage` < 0 keeps the bullet's damage. Does not emit signals.
	bool apply_reflect(int p_slot, int p_new_owner, int p_new_mask, const godot::Color &p_color, float p_new_damage,
			bool p_keep_script, int p_limit, const godot::Vector2 &p_heading, float p_speed, const godot::Vector2 &p_impact);
	// The outbound wall hit no longer counts: the bullet turned before it.
	void cancel_outbound_wall(int p_slot);
	// Flies the rest of the tick from the impact. Queues return-leg hurtbox hits;
	// the caller commits them, then finish_return() applies a wall on that leg.
	void begin_return(int p_slot, double p_delta, float p_reflected_t);
	int get_return_hit_count() const { return (int)return_events.size(); }
	void commit_return_hit(int p_index);
	void finish_return(int p_slot);

	// Surface normal of the wall this id hit this step, or ZERO. Valid from the
	// wall clip until clear_wall_normals() (the despawn-hook window).
	godot::Vector2 get_wall_normal(int64_t p_id) const;
	void clear_wall_normals();
	// Same normal WallGrid.first_hit would report for this path, for tests.
	godot::Vector2 query_wall_normal(const godot::Vector2 &p_start, const godot::Vector2 &p_delta, float p_radius);
	// Writes the live bullets into the MultiMesh buffers and uploads them.
	// Returns the live count (use it as visible_instance_count).
	int upload(const godot::RID &p_multimesh, int p_allocated, bool p_interpolate, float p_stretch);

	// --- bullets ---------------------------------------------------------
	// p_seq is the shared spawn-order slot (BulletManager). It is the key hit
	// resolution sorts by when bullets live in both stores.
	int64_t spawn(const godot::Vector2 &p_position, const godot::Vector2 &p_velocity, float p_angle, float p_lifetime,
			float p_radius, float p_damage, int p_hit_mask, const godot::Color &p_color, float p_acceleration,
			float p_turn_rate, int p_pierce, bool p_collide_world, int p_owner_layer, int p_source_flags, int p_seq,
			int p_behavior, float p_param_a, float p_param_b);
	// Packed copies of every alive bullet with this behavior id, in slot order.
	// The id column is the stable id. A later write is applied only if it still matches.
	godot::Dictionary gather_batch(int p_behavior) const;
	// Writes velocity and params for each id. A stale generation or a dead bullet
	// is skipped. Non-finite velocity or params kill as INVALID. The dictionary
	// is the whole commit (no per-row callback): totals killed, vel_nonfinite,
	// pa_nonfinite, pb_nonfinite, and clamp_vx/clamp_vy for each finite over-cap
	// velocity. warn_row, warn_key, warn_what, warn_vx and warn_vy are the same
	// events in row order (row index, ScriptWarnings key, the removal text or
	// empty, and the pre-clamp velocity). A row can record a speed clamp and
	// then a param kill. Emission walks that list so the printed subset matches
	// the pool.
	godot::Dictionary apply_batch(const godot::PackedInt64Array &p_ids, const godot::PackedFloat32Array &p_vx,
			const godot::PackedFloat32Array &p_vy, const godot::PackedFloat32Array &p_pa,
			const godot::PackedFloat32Array &p_pb);
	bool teleport_id(int64_t p_id, float p_x, float p_y);
	int count_with_behavior(int p_behavior) const;
	// Called with the removed bullet's seq before the slot is overwritten, so the
	// manager can hand that seq to the global tail (unified swap-remove).
	void set_retire_callback(const godot::Callable &p_cb) { retire_order = p_cb; }
	bool is_alive(int64_t p_id) const;
	int slot_of(int64_t p_id) const;
	int64_t id_of(int p_slot) const;
	// Marks a bullet for removal (reason MANUAL); it disappears at the next step().
	bool kill(int64_t p_id);
	void clear();

	// --- inspection ------------------------------------------------------
	int get_count() const { return count; }
	int get_capacity() const { return capacity; }
	int get_logical_cap() const { return logical_cap; }
	int get_enemy_reserve() const { return enemy_reserve; }
	int64_t get_spawned_total() const { return spawned_total; }
	int64_t get_dropped_total() const { return dropped_total; }
	int64_t get_invalid_total() const { return invalid_total; }
	int get_owner_count(int p_layer) const;
	godot::PackedInt32Array get_owner_counts() const;
	godot::PackedInt32Array get_dropped_by_owner() const;
	godot::PackedInt32Array get_dropped_by_limit() const;
	float get_max_radius() const { return max_radius; }
	int get_last_hit_count() const { return last_hit_count; }
	int get_last_wall_hit_count() const { return last_wall_hit_count; }
	godot::PackedInt32Array get_despawn_counts() const;
	godot::Dictionary snapshot() const;
	void set_record_events(bool p_on) { record_events = p_on; }
	godot::Array get_last_hits() const;
	// Removals from the last step(), in compact order: lifetime, reason.
	// Empty unless set_record_events(true) was set. Filled by deliver_hits().
	godot::Array get_last_despawns() const;

protected:
	static void _bind_methods();

private:
	struct HitEvent {
		uint64_t target_id;
		int64_t bullet_id;
		float x, y, vx, vy, damage;
		int32_t flags;
		int32_t seq;
		float path_t;
	};
	struct DespawnEvent {
		float lifetime;
		int32_t reason;
		float nx, ny;
	};
	struct ZoneEvent {
		int32_t slot;
		int32_t zone;
		float t;
		int32_t seq;
	};
	struct WallReport {
		int64_t id;
		float nx, ny;
	};
	struct WallContact {
		double t = -1.0;
		int wall = -1;
		float nx = 0.0f;
		float ny = 0.0f;
	};
	// Same cap as HurtboxGrid.MAX_ZONE_HITS.
	static constexpr int MAX_ZONE_HITS = 4;

	// ---- bullet storage (dense [0, count)) ----
	int capacity = 0;
	int count = 0;
	std::vector<float> px, py, qx, qy, vx, vy, rx, ry;
	std::vector<float> radius, age, lifetime, accel, turn, damage, param_a, param_b;
	std::vector<float> col; // 4 per bullet
	std::vector<int32_t> hit_mask, pierce, owner_layer, seq, behavior;
	std::vector<uint8_t> collide_world, dead, source_flags, reflect_count;
	// Per-step wall bookkeeping. wall_clip is the fraction of the tick the
	// outbound path survived (1 = no wall). wall_suppress drops that hit when
	// a mirror turns the bullet first. wall_report is the normal hooks may read.
	std::vector<float> wall_clip, wall_nx, wall_ny;
	std::vector<uint8_t> wall_suppress, wall_report, return_wall_pending;
	// Pierce-hit ring, HIT_MEMORY per slot. Count 0 means the window is unread.
	std::vector<uint64_t> hit_mem;
	std::vector<uint8_t> hit_mem_count, hit_mem_head;
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
	int logical_cap = 0;
	int enemy_reserve = 0;
	int other_limit = 0;
	// Occupancy of the other backend. Added to `count` when a spawn is admitted.
	int external_count = 0;
	int64_t owner_counts[3] = { 0, 0, 0 };
	int64_t dropped_by_owner[3] = { 0, 0, 0 };
	int64_t dropped_by_limit[2] = { 0, 0 };
	float max_radius = 0.0f;
	float min_target_radius = 0.0f;
	int last_hit_count = 0;
	int last_wall_hit_count = 0;
	int64_t despawn_counts[7] = { 0, 0, 0, 0, 0, 0, 0 };
	int64_t invalid_total = 0;

	// ---- world ----
	godot::Rect2 bounds;
	float cell_size = 64.0f;
	// Speed ceiling from BulletLimits.MAX_SPEED (0 = not configured, no accel clamp).
	float max_speed = 0.0f;
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

	// ---- reflector zones (separate hash; rebuilt each step they exist) ----
	struct Zone {
		float x, y, r;
		int32_t layer;
	};
	std::vector<Zone> zones;
	int zone_count = 0;
	std::vector<int32_t> z_heads;
	std::vector<uint8_t> z_occupied;
	std::vector<int32_t> z_touched;
	std::vector<int32_t> z_entry_next, z_entry_target;
	int z_entry_count = 0;
	std::vector<ZoneEvent> zone_events;
	std::vector<HitEvent> return_events;
	std::vector<WallReport> wall_reports;

	// ---- walls (static; CSR cell lists rebuilt on change) ----
	std::vector<float> wall_lo_x, wall_lo_y, wall_hi_x, wall_hi_y;
	std::vector<int32_t> w_cell_start; // cols*rows + 1
	std::vector<int32_t> w_cell_walls;
	bool walls_dirty = true;

	// ---- events ----
	std::vector<HitEvent> hit_events;
	bool record_events = false;
	std::vector<HitEvent> hit_log;
	std::vector<DespawnEvent> despawn_log;
	// Slots that touched a wall this step. Applied after hit delivery so a
	// hurtbox in front of the wall still wins the despawn reason.
	std::vector<int32_t> wall_slots;
	// Per-bullet pierce exclusion list. Grows; there is no fixed cap.
	std::vector<int32_t> excl_buf;
	godot::Callable retire_order;
	void commit_hit(const HitEvent &h);

	// ---- render buffers: two alternating sets, see upload() ----
	godot::PackedFloat32Array cur_buf[2];
	godot::PackedFloat32Array prev_buf[2];
	int buf_set = 0;

	struct IntegratedMotion {
		float vx = 0.0f;
		float vy = 0.0f;
		float rx = 1.0f;
		float ry = 0.0f;
		float nx = 0.0f;
		float ny = 0.0f;
		bool expired = false;
		bool out_of_bounds = false;
	};
	// 1 when integrate() left this slot for collide(). The fast step() does not use it.
	std::vector<uint8_t> collide_mark;
	void begin_step();
	IntegratedMotion compute_motion(int i, double delta, float fdelta, float min_x, float min_y, float max_x, float max_y) const;
	bool integrate_one(int i, double delta, float fdelta, float min_x, float min_y, float max_x, float max_y);
	void collide_one(int i, bool have_walls, bool have_targets);
	void rebuild_hash();
	void rebuild_walls();
	void mark_dead(int slot, int reason);
	void claim_from_bounds(int slot, int reason);
	void remove_at(int slot);
	void compact();
	bool id_valid(int64_t p_id, uint32_t &r_handle) const;
	void reset_handles();
	int owner_slot_of(int layer) const;
	void note_drop(int owner_slot, bool at_cap);
	void clear_hit_memory(int slot);
	void remember_target(int slot, uint64_t target_id);
	bool is_remembered(int slot, uint64_t target_id) const;
	void copy_hit_memory(int src, int dst);

	double wall_first_hit(double sx, double sy, double dx, double dy, double r) const;
	WallContact query_wall(double sx, double sy, double dx, double dy, double r) const;
	int sweep_targets(double sx, double sy, double dx, double dy, double r, int mask, int slot,
			const int32_t *excl, int excl_n, double &r_t) const;
	bool point_hit(double x, double y, double r, int mask, int slot, int &r_target) const;
	void rebuild_zones();
	void sweep_zones_for(int slot, float sx, float sy, float dx, float dy, float br, int mask);
	void resize_zone_grid();
	static void box_normal(float sx, float sy, float dx, float dy, float lox, float loy, float hix, float hiy, float &nx, float &ny);
};

} // namespace scriptshot

VARIANT_ENUM_CAST(scriptshot::NativeBulletSim::DespawnReason);

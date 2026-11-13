extends SceneTree
## Captures a still of the vertical-slice HUD into /workspace/slice-hud-shot.png.
## Not part of CI. Run: godot --path . --headless -s tools/slice_hud_shot.gd

func _initialize() -> void:
	call_deferred("_go")


func _go() -> void:
	var err := await _capture()
	quit(err)


func _capture() -> int:
	var vp := SubViewport.new()
	vp.size = Vector2i(1280, 720)
	vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	vp.transparent_bg = false
	root.add_child(vp)
	var bg := ColorRect.new()
	bg.color = Color("0B0D10")
	bg.size = Vector2(1280, 720)
	vp.add_child(bg)
	var world := Node2D.new()
	world.position = Vector2(640, 360)
	vp.add_child(world)
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	world.add_child(player)
	var progress := SliceProgress.new()
	world.add_child(progress)
	var hud := SliceHud.new()
	world.add_child(hud)
	await process_frame
	await process_frame
	progress.bind(player, null, null, null)
	hud.bind(player, progress)
	# A mid-fight still: 3 pips, dash cooling, one Sense filled, a hint, a toast,
	# and a boss arc at half health.
	player.health.hp = 3.0
	hud._on_hp_changed(3.0, 5.0)
	player.try_dash(Vector2.RIGHT)
	hud._process(0.0)
	SenseBook.grant(&"nearest_enemy", 1)
	hud._show_hint(1)
	var boss := Node2D.new()
	world.add_child(boss)
	hud.set_boss_health(450.0, 900.0)
	# The arc is a child of the HUD until bind_boss; pin it next to the player.
	hud._boss.position = Vector2(120, 0)
	hud._boss._shown = true
	hud._boss.queue_redraw()
	# A few frames so the viewport presents.
	for _i in 8:
		await process_frame
	var img := vp.get_texture().get_image()
	if img == null:
		push_error("slice_hud_shot: viewport image was empty")
		SenseBook.reset()
		return 1
	var dest := "/workspace/slice-hud-shot.png"
	var saved := img.save_png(dest)
	SenseBook.reset()
	if saved != OK:
		push_error("slice_hud_shot: save_png failed (%d)" % saved)
		return 1
	print("wrote ", dest)
	return 0

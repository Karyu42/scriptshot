extends Node
## Captures a still of the vertical-slice HUD into /workspace/slice-hud-shot.png.
## Not part of CI. Run as a scene so autoloads (InputDevice, RespawnPoints)
## are present. The dummy headless renderer cannot read viewport textures, so
## this needs a real display: godot --path . res://tools/slice_hud_shot.tscn

func _ready() -> void:
	call_deferred("_go")


func _go() -> void:
	var err := await _capture()
	get_tree().quit(err)


func _capture() -> int:
	var tree := get_tree()
	var win := get_window()
	if win != null:
		win.size = Vector2i(1280, 720)
	var bg := ColorRect.new()
	bg.color = Color("0B0D10")
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	var world := Node2D.new()
	world.position = Vector2(640, 360)
	add_child(world)
	var player := (load("res://scenes/player.tscn") as PackedScene).instantiate() as Player
	world.add_child(player)
	var progress := SliceProgress.new()
	world.add_child(progress)
	var hud := SliceHud.new()
	world.add_child(hud)
	await tree.process_frame
	await tree.process_frame
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
	boss.position = Vector2(120, 0)
	world.add_child(boss)
	hud.bind_boss(boss)
	hud.set_boss_health(450.0, 900.0)
	hud._boss.queue_redraw()
	for _i in 12:
		await tree.process_frame
		RenderingServer.force_draw()
	var img := get_viewport().get_texture().get_image()
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

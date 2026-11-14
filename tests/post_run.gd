extends GutHookScript
## Stop leftover sting players before the process quits so the audio
## server is not still mixing them during shutdown.


func run() -> void:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		RaritySting.reset_session()
		return
	_stop_tree(tree.root)
	RaritySting.reset_session()


func _stop_tree(node: Node) -> void:
	if node is RaritySting:
		(node as RaritySting).shutdown()
		return
	if node is AudioStreamPlayer:
		var player := node as AudioStreamPlayer
		if player.playing:
			player.stop()
		player.stream = null
		return
	for child in node.get_children():
		_stop_tree(child)

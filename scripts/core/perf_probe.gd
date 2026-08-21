class_name PerfProbe
extends RefCounted
## QA-only frame-time sampler (AgentBridge `perf`): samples a window of frames and
## reports where the frame goes — script process time, physics, draw calls, node
## counts. Built for the CPU-bound perf hunt (RTX 5090 at 40% GPU = the main thread
## is the bottleneck); every optimization lands with a before/after capture.
## `world_children` doubles as the lobby-teardown probe (0 = no lingering arena).


static func capture(tree: SceneTree, window_s: float = 1.0) -> Dictionary:
	window_s = clampf(window_s, 0.1, 10.0)
	var deltas: Array[float] = []
	var process_sum := 0.0
	var physics_sum := 0.0
	var draws_sum := 0.0
	var objects_sum := 0.0
	var start_us := Time.get_ticks_usec()
	var last_us := start_us
	while (Time.get_ticks_usec() - start_us) / 1_000_000.0 < window_s:
		await tree.process_frame
		var now_us := Time.get_ticks_usec()
		deltas.append(float(now_us - last_us) / 1000.0)  # ms
		last_us = now_us
		process_sum += Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0
		physics_sum += Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0
		draws_sum += Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
		objects_sum += Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)
	var n := deltas.size()
	if n == 0:
		return {"ok": false, "error": "no frames sampled"}
	deltas.sort()
	var sum := 0.0
	for d in deltas:
		sum += d
	var avg_ms := sum / float(n)
	var world_children := -1
	var main := tree.current_scene
	if main != null:
		var wr := main.get_node_or_null("WorldRoot")
		if wr != null:
			world_children = wr.get_child_count()
	return {
		"ok": true,
		"frames": n,
		"fps_avg": snappedf(1000.0 / maxf(avg_ms, 0.001), 0.1),
		"frame_ms":
		{
			"avg": snappedf(avg_ms, 0.01),
			"min": snappedf(deltas[0], 0.01),
			"max": snappedf(deltas[n - 1], 0.01),
			"p95": snappedf(deltas[mini(int(float(n) * 0.95), n - 1)], 0.01),
		},
		"process_ms_avg": snappedf(process_sum / float(n), 0.01),
		"physics_ms_avg": snappedf(physics_sum / float(n), 0.01),
		"draw_calls_avg": snappedf(draws_sum / float(n), 0.1),
		"objects_avg": snappedf(objects_sum / float(n), 0.1),
		"node_count": int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		"orphan_nodes": int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		"resources": int(Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT)),
		"static_mem_mb":
		snappedf(Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0, 0.1),
		"world_children": world_children,
	}

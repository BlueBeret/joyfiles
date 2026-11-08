extends SceneTree

# prints the contrast of every pair that the UI draws and exits 1 when one falls under its minimum


func _initialize() -> void:
	var failed := 0
	for row: Array in Theme_.contrast_rows():
		var ok: bool = row[1] >= row[2]
		if not ok:
			failed += 1
		print("%s %-26s %5.2f (min %.1f)" % ["PASS" if ok else "FAIL", row[0], row[1], row[2]])
	print("RESULT %s (%d below the minimum)" % ["OK" if failed == 0 else "FAILED", failed])
	quit(failed)

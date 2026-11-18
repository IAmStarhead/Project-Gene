## Minimal hit receiver for the deterministic combat integration test.
extends Node3D

var hits := 0
var total_damage := 0.0

func take_damage(amount: float, _direction: Vector3) -> void:
	hits += 1
	total_damage += amount

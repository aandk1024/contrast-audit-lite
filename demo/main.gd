extends Control

## The demo screen. Pressing play shows it exactly as the checks measure it,
## which is the point: every fault the dock reports is one you can see here
## with your own eyes, at the size and colour the player would get.

func _ready() -> void:
	var close: Button = $Rows/Card/CardRow/Close
	close.pressed.connect(func() -> void:
		# Not get_tree().quit(), because the demo is also opened from the
		# editor where quitting the tree is not what anyone wants.
		$Rows/Card.visible = false)

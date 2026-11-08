@tool
extends EditorPlugin

# =============================================================================
# LOWPOLY TERRAIN EDITOR - MVP
#
# Everything is intentionally contained in this single plugin script for now.
#
# Editable semantic data is stored as metadata on the generated terrain Node3D:
#
#   mask        -> island occupancy
#   heights     -> base sculpted heights
#   roads       -> arrays of Vector2 path points
#   rivers      -> arrays of Vector2 path points
#
# The actual ArrayMesh is disposable and regenerated from that data.
# =============================================================================

class TerrainInspectorPlugin extends EditorInspectorPlugin:
	var host: EditorPlugin
	var _foldout_states: Dictionary = {}

	func _init(p_host: EditorPlugin) -> void:
		host = p_host

	func _can_handle(object: Object) -> bool:
		return object is Node3D and object.has_meta("_lowpoly_terrain") and bool(object.get_meta("_lowpoly_terrain"))

	func _parse_begin(object: Object) -> void:
		var terrain := object as Node3D
		host.call("_install_terrain_inspector_properties", terrain)

		var panel := VBoxContainer.new()
		panel.name = "LowPoly Terrain"

		var title := Label.new()
		title.text = "LowPoly Terrain"
		title.add_theme_font_size_override("font_size", 16)
		panel.add_child(title)

		# ---------------------------------------------------------------------
		# Canvas
		# ---------------------------------------------------------------------
		var canvas := _add_foldout(panel, "Canvas", true)

		var current_resolution: int = int(terrain.get_meta("_lte_resolution", 48))
		var current_world_size: float = float(terrain.get_meta("_lte_world_size", 48.0))
		var current_spacing: float = current_world_size / maxf(float(current_resolution - 1), 1.0)
		_add_help_text(
			canvas,
			"Canvas size: %.1f x %.1f units | %d x %d vertices | %.3f unit spacing"
			% [current_world_size, current_world_size, current_resolution, current_resolution, current_spacing]
		)

		var auto_expand := CheckBox.new()
		auto_expand.text = "Auto-expand while painting"
		auto_expand.tooltip_text = "Grow the terrain grid when Paint approaches the current boundary."
		auto_expand.button_pressed = bool(terrain.get_meta("_lte_auto_expand", true))
		auto_expand.toggled.connect(func(enabled: bool) -> void:
			host.call("_set_canvas_setting", terrain, "_lte_auto_expand", enabled)
		)
		canvas.add_child(auto_expand)

		_add_canvas_int_control(canvas, terrain, "Expansion Chunk", "_lte_expand_chunk", 1, 64, 8, "Grid cells added to each side when the canvas grows.")
		_add_canvas_int_control(canvas, terrain, "Maximum Resolution", "_lte_max_resolution", 64, 1024, 256, "Safety limit for automatic canvas growth.")

		var grow_button := Button.new()
		grow_button.text = "Grow Canvas"
		grow_button.tooltip_text = "Grow the canvas by one Expansion Chunk on every side."
		grow_button.pressed.connect(func() -> void:
			host.call("_grow_canvas_from_inspector", terrain)
		)
		canvas.add_child(grow_button)

		# ---------------------------------------------------------------------
		# Procedural Map Generator
		# ---------------------------------------------------------------------
		var generator := _add_foldout(panel, "Procedural Map Generator", true)
		_add_help_text(generator, "How to use: Upload a pixel art image to generate terrain.")
		_add_help_text(generator, "Supports 4 colors: WHITE / TRANSPARENT = empty, GREEN = ground, RED = raised ground, BLUE = indented ground.")
		_add_help_text(generator, "Recommended size: 1x1 to 256x256.")

		_add_generator_texture_control(generator, terrain, "Source Pixel Map", "_lte_generator_image", "Pixel-art source map used for terrain generation.")
		var generator_height_max: float = maxf(0.0, float(terrain.get_meta("_lte_height_max", 8.0)))
		var generator_depth_max: float = maxf(0.0, -float(terrain.get_meta("_lte_height_min", -3.0)))
		_add_generator_float_control(generator, terrain, "Raised Ground Height", "_lte_generator_raise_height", 0.0, generator_height_max, 0.1, minf(2.0, generator_height_max), "Target elevation for RED pixels. Limited by Geometry Tuning > Terrain Height Max.")
		_add_generator_float_control(generator, terrain, "Indented Ground Depth", "_lte_generator_lower_depth", 0.0, generator_depth_max, 0.1, minf(1.0, generator_depth_max), "Target depth for BLUE pixels. Limited by Geometry Tuning > Terrain Height Min.")
		_add_generator_float_control(generator, terrain, "Color Tolerance", "_lte_generator_color_tolerance", 0.0, 0.5, 0.01, 0.08, "Allowed color variation when matching WHITE/GREEN/RED/BLUE.")
		_add_generator_float_control(generator, terrain, "Height / Dent Smoothness", "_lte_generator_smoothness", 0.0, 32.0, 0.5, 0.0, "Transition width in cells. 0 keeps RED / BLUE regions flat; higher values turn them into smoother hills and dents.")

		var material_settings := _add_foldout(generator, "Material Settings", false)
		_add_help_text(
			material_settings,
			"How to use: Assign a material to each color map individually or use Manual Brush Settings. "
			+ "If Manual Brush Settings are used, GREEN / RED / BLUE all share one top color, side color and texture setup."
		)

		var use_manual := CheckBox.new()
		use_manual.text = "Use Manual Brush Settings"
		use_manual.tooltip_text = "When enabled, GREEN / RED / BLUE all use the Manual Brush Settings below. Individual material presets remain visible and saved, but are ignored until this option is turned off."
		use_manual.button_pressed = bool(terrain.get_meta("_lte_generator_use_single_style", true))
		use_manual.toggled.connect(func(enabled: bool) -> void:
			host.call("_set_generator_setting", terrain, "_lte_generator_use_single_style", enabled)
		)
		material_settings.add_child(use_manual)

		_add_help_text(
			material_settings,
			"Uncheck 'Use Manual Brush Settings' to assign textures and colors individually."
		)

		var individual_materials := VBoxContainer.new()
		material_settings.add_child(individual_materials)
		_add_generator_style_section(individual_materials, terrain, "GREEN / Ground", "green")
		_add_generator_style_section(individual_materials, terrain, "RED / Raised Ground", "red")
		_add_generator_style_section(individual_materials, terrain, "BLUE / Indented Ground", "blue")

		var generate_button := Button.new()
		generate_button.text = "Generate from Image"
		generate_button.tooltip_text = "Rebuild the terrain from the assigned pixel map. This operation supports Undo/Redo."
		generate_button.pressed.connect(func() -> void:
			host.call("_generate_from_image", terrain)
		)
		generator.add_child(generate_button)

		# ---------------------------------------------------------------------
		# Manual Brush Settings
		# ---------------------------------------------------------------------
		var manual := _add_foldout(panel, "Manual Brush Settings", false)
		_add_help_text(
			manual,
			"How to use: Select colors and textures for newly painted cells. "
			+ "For example, paint grass terrain, then swap colors/textures and continue painting rocks."
		)

		_add_color_control(manual, terrain, "Top Color", "_lte_brush_top_color", Color(0.44, 0.69, 0.20), "Fallback color for newly painted top faces when Top Texture is empty.")
		_add_color_control(manual, terrain, "Side Color", "_lte_brush_cliff_color", Color(0.45, 0.25, 0.13), "Fallback color for newly exposed sides when Side Texture is empty.")
		_add_texture_control(manual, terrain, "Top Texture", "_lte_brush_top_texture", "Optional repeating texture for newly painted top faces.")
		_add_float_control(manual, terrain, "Top Texture Tile Size", "_lte_brush_top_tile_size", 0.1, 64.0, 0.1, 4.0, "World-space size of one top texture repeat.")
		_add_texture_control(manual, terrain, "Side Texture", "_lte_brush_cliff_texture", "Optional repeating texture for newly exposed side walls.")
		_add_float_control(manual, terrain, "Side Texture Tile Size", "_lte_brush_cliff_tile_size", 0.1, 64.0, 0.1, 4.0, "World-space size of one side texture repeat.")

		# ---------------------------------------------------------------------
		# Terrain Features
		# ---------------------------------------------------------------------
		var features := _add_foldout(panel, "Terrain Features", false)
		_add_help_text(
			features,
			"How to use: Roads and rivers are special terrain features with their own painting styles and behavior."
		)

		var roads := _add_foldout(features, "Roads", false)
		_add_feature_float_control(roads, terrain, "Road Width", "_lte_road_width", 0.25, 16.0, 0.1, 2.6, "Width of newly drawn roads.")
		_add_feature_float_control(roads, terrain, "Road Y Offset", "_lte_road_y_offset", -1.0, 2.0, 0.005, 0.035, "Vertical road offset used to avoid z-fighting.")
		_add_feature_color_control(roads, terrain, "Road Color", "_lte_road_color", Color(0.76, 0.56, 0.31), "Road color used when Road Texture is empty.")
		_add_feature_texture_control(roads, terrain, "Road Texture", "_lte_road_texture", "Optional repeating texture for roads.")
		_add_feature_float_control(roads, terrain, "Road Texture Tile Size", "_lte_road_tile_size", 0.1, 64.0, 0.1, 4.0, "Approximate world-space length of one road texture repeat.")

		var rivers := _add_foldout(features, "Rivers", false)
		_add_help_text(
			rivers,
			"How to use: Leave Water Normal Texture empty to use the built-in generated normal. You can also assign an Albedo Texture or create and edit a Normal NoiseTexture2D."
		)
		_add_feature_float_control(rivers, terrain, "River Width", "_lte_river_width", 0.25, 24.0, 0.1, 3.3, "Width of newly drawn rivers and their carved channel.")
		_add_feature_float_control(rivers, terrain, "River Depth", "_lte_river_depth", 0.0, 8.0, 0.05, 0.65, "Depth of the carved river bed.")
		_add_feature_float_control(rivers, terrain, "Water Surface Drop", "_lte_river_surface_drop", -1.0, 4.0, 0.01, 0.15, "Distance between original terrain surface and river water.")
		_add_feature_color_control(rivers, terrain, "Water Color", "_lte_river_color", Color(0.12, 0.38, 0.55, 0.72), "Water tint and alpha.")
		_add_feature_texture_control(rivers, terrain, "Water Albedo Texture", "_lte_river_texture", "Optional repeating water albedo texture.")
		_add_water_normal_texture_control(rivers, terrain)
		_add_feature_float_control(rivers, terrain, "Water Texture Tile Size", "_lte_river_tile_size", 0.1, 128.0, 0.1, 6.0, "World-space size of one water texture repeat.")
		_add_feature_float_control(rivers, terrain, "Water Roughness", "_lte_river_roughness", 0.0, 1.0, 0.01, 0.18, "Lower values produce shinier water.")
		_add_feature_float_control(rivers, terrain, "Normal Strength", "_lte_river_normal_strength", 0.0, 4.0, 0.05, 0.8, "Strength of the animated water normal.")
		_add_feature_float_control(rivers, terrain, "Refraction Strength", "_lte_river_refraction", 0.0, 0.08, 0.001, 0.012, "Screen-space refraction amount.")
		_add_feature_float_control(rivers, terrain, "Flow Speed", "_lte_river_flow_speed", -1.0, 1.0, 0.005, 0.03, "Water texture/normal scrolling speed.")
		_add_feature_float_control(rivers, terrain, "Flow Direction", "_lte_river_flow_angle", -180.0, 180.0, 1.0, 32.211, "Water flow angle in world X/Z space. 0° flows toward +X, 90° toward +Z, -90° toward -Z. Use this to make water visually flow downhill.")

		# ---------------------------------------------------------------------
		# Collisions
		# ---------------------------------------------------------------------
		var collisions := _add_foldout(panel, "Collisions", false)

		var collision_enabled := CheckBox.new()
		collision_enabled.text = "Generate walkable collision"
		collision_enabled.tooltip_text = "Generate/update terrain collision from the visible terrain geometry."
		collision_enabled.button_pressed = bool(terrain.get_meta("_lte_collision_enabled", false))
		collision_enabled.toggled.connect(func(enabled: bool) -> void:
			host.call("_set_tuning_meta", terrain, "_lte_collision_enabled", enabled)
		)
		collisions.add_child(collision_enabled)

		_add_int_control(collisions, terrain, "Collision Layer", "_lte_collision_layer", 1, 32, 1, "Physics layer used by generated terrain collision.")
		_add_feature_checkbox(collisions, terrain, "Road collision", "_lte_road_collision", true, "Include committed roads in generated collision.")
		_add_feature_checkbox(collisions, terrain, "Water surface collision", "_lte_river_collision", false, "Enable only when actors should collide with the water surface instead of the carved river bed.")

		# ---------------------------------------------------------------------
		# Geometry Tuning
		# ---------------------------------------------------------------------
		var geometry := _add_foldout(panel, "Geometry Tuning", false)
		_add_help_text(geometry, "To change the world height adjust Terrain Height Max (how high the mountains can grow) and Base Y + Terrain Height Min (how deep you can lower the ground).")
		_add_float_control(geometry, terrain, "Base Y", "_lte_base_y", -32.0, 8.0, 0.05, -3.0, "Bottom of the vertical cliff shell.")
		_add_float_control(geometry, terrain, "Terrain Height Min", "_lte_height_min", -128.0, 0.0, 0.1, -3.0, "Lowest sculpted height relative to the terrain zero-height surface. Procedural dents cannot go below this value.")
		_add_float_control(geometry, terrain, "Terrain Height Max", "_lte_height_max", 0.0, 128.0, 0.1, 8.0, "Highest sculpted height relative to the terrain zero-height surface. Procedural raised ground cannot exceed this value.")
		_add_float_control(geometry, terrain, "Top Y Offset", "_lte_top_y_offset", -0.5, 0.5, 0.005, 0.0, "Vertical alignment offset for terrain top faces.")
		_add_float_control(geometry, terrain, "Cliff Y Offset", "_lte_cliff_y_offset", -0.5, 0.5, 0.005, 0.0, "Vertical alignment offset for cliff top edges.")
		_add_float_control(geometry, terrain, "Feature Y Offset", "_lte_feature_y_offset", -0.5, 0.5, 0.005, 0.0, "Additional global vertical offset for roads and rivers.")

		# ---------------------------------------------------------------------
		# Rendering
		# ---------------------------------------------------------------------
		var rendering := _add_foldout(panel, "Rendering", false)
		_add_help_text(
			rendering,
			"How to use: Keep Double-sided Faces OFF for correct exterior lighting. "
			+ "If some generated or painted faces are unexpectedly invisible, turn it ON for troubleshooting."
		)

		_add_float_control(rendering, terrain, "Top Normal Up Bias", "_lte_top_normal_up_bias", 0.0, 1.0, 0.05, 0.0, "0 = low-poly face normals; 1 = force top lighting upward.")

		var double_sided := CheckBox.new()
		double_sided.text = "Double-sided Faces"
		double_sided.tooltip_text = "Disable back-face culling. Normally leave this OFF."
		double_sided.button_pressed = bool(terrain.get_meta("_lte_double_sided", false))
		double_sided.toggled.connect(func(enabled: bool) -> void:
			host.call("_set_tuning_meta", terrain, "_lte_double_sided", enabled)
		)
		rendering.add_child(double_sided)

		add_custom_control(panel)

	func _add_foldout(parent: VBoxContainer, title_text: String, expanded: bool = false) -> VBoxContainer:
		var header := Button.new()
		header.toggle_mode = true
		header.alignment = HORIZONTAL_ALIGNMENT_LEFT
		header.flat = true
		header.focus_mode = Control.FOCUS_NONE
		parent.add_child(header)

		# Remember UI state inside the Inspector plugin instance. Godot can rebuild
		# a custom Inspector after changing resources, colors or metadata, so the
		# default argument alone is not enough to preserve nested foldouts.
		var initial_open: bool = bool(_foldout_states.get(title_text, expanded))
		header.button_pressed = initial_open

		var indent_row := HBoxContainer.new()
		parent.add_child(indent_row)

		var spacer := Control.new()
		spacer.custom_minimum_size.x = 12.0
		indent_row.add_child(spacer)

		var body := VBoxContainer.new()
		body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		body.visible = initial_open
		indent_row.add_child(body)

		# Closed sections use a cool accent; the currently open section uses a
		# different warm/green accent. Both stay equally prominent in size.
		var closed_color := Color(0.64, 0.82, 1.00)
		var closed_hover_color := Color(0.78, 0.90, 1.00)
		var open_color := Color(0.64, 0.93, 0.72)
		var open_hover_color := Color(0.78, 1.00, 0.84)

		var update_header := func(open: bool) -> void:
			_foldout_states[title_text] = open
			header.text = ("▼ " if open else "▶ ") + title_text
			body.visible = open
			header.add_theme_font_size_override("font_size", 14)

			if open:
				header.add_theme_color_override("font_color", open_color)
				header.add_theme_color_override("font_pressed_color", open_color)
				header.add_theme_color_override("font_hover_color", open_hover_color)
			else:
				header.add_theme_color_override("font_color", closed_color)
				header.add_theme_color_override("font_pressed_color", closed_color)
				header.add_theme_color_override("font_hover_color", closed_hover_color)

		update_header.call(initial_open)
		header.toggled.connect(update_header)
		return body

	func _add_help_text(parent: VBoxContainer, value: String) -> void:
		var label := Label.new()
		label.text = value
		label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		label.add_theme_color_override("font_color", Color(0.66, 0.68, 0.72))
		label.add_theme_font_size_override("font_size", 12)
		parent.add_child(label)

	func _add_float_control(
		parent: VBoxContainer, terrain: Node3D, label_text: String, key: String,
		min_value: float, max_value: float, step: float, default_value: float, tooltip: String
	) -> void:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var spin := SpinBox.new()
		spin.min_value = min_value
		spin.max_value = max_value
		spin.step = step
		spin.value = float(terrain.get_meta(key, default_value))
		spin.tooltip_text = tooltip
		spin.custom_minimum_size.x = 110.0
		spin.value_changed.connect(func(value: float) -> void:
			host.call("_set_tuning_meta", terrain, key, value)
		)
		row.add_child(spin)
		parent.add_child(row)

	func _add_int_control(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, min_value: int, max_value: int, default_value: int, tooltip: String) -> void:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var spin := SpinBox.new()
		spin.min_value = min_value
		spin.max_value = max_value
		spin.step = 1
		spin.value = int(terrain.get_meta(key, default_value))
		spin.tooltip_text = tooltip
		spin.custom_minimum_size.x = 110.0
		spin.value_changed.connect(func(value: float) -> void:
			host.call("_set_tuning_meta", terrain, key, int(value))
		)
		row.add_child(spin)
		parent.add_child(row)

	func _add_canvas_int_control(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, min_value: int, max_value: int, default_value: int, tooltip: String) -> void:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var spin := SpinBox.new()
		spin.min_value = min_value
		spin.max_value = max_value
		spin.step = 1
		spin.value = int(terrain.get_meta(key, default_value))
		spin.tooltip_text = tooltip
		spin.custom_minimum_size.x = 110.0
		spin.value_changed.connect(func(value: float) -> void:
			host.call("_set_canvas_setting", terrain, key, int(value))
		)
		row.add_child(spin)
		parent.add_child(row)

	func _add_color_control(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, default_value: Color, tooltip: String) -> void:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var picker := ColorPickerButton.new()
		picker.color = terrain.get_meta(key, default_value)
		picker.tooltip_text = tooltip
		picker.custom_minimum_size = Vector2(110.0, 28.0)
		picker.color_changed.connect(func(value: Color) -> void:
			host.call("_set_paint_setting", terrain, key, value)
		)
		row.add_child(picker)
		parent.add_child(row)

	func _add_feature_float_control(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, min_value: float, max_value: float, step: float, default_value: float, tooltip: String) -> void:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = min_value
		spin.max_value = max_value
		spin.step = step
		spin.value = float(terrain.get_meta(key, default_value))
		spin.tooltip_text = tooltip
		spin.custom_minimum_size.x = 110.0
		spin.value_changed.connect(func(value: float) -> void:
			host.call("_set_feature_setting", terrain, key, value)
		)
		row.add_child(spin)
		parent.add_child(row)

	func _add_feature_color_control(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, default_value: Color, tooltip: String) -> void:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var picker := ColorPickerButton.new()
		picker.color = terrain.get_meta(key, default_value)
		picker.edit_alpha = true
		picker.tooltip_text = tooltip
		picker.custom_minimum_size.x = 110.0
		picker.color_changed.connect(func(value: Color) -> void:
			host.call("_set_feature_setting", terrain, key, value)
		)
		row.add_child(picker)
		parent.add_child(row)

	func _add_feature_texture_control(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, tooltip: String) -> void:
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		parent.add_child(label)
		var picker := EditorResourcePicker.new()
		picker.base_type = "Texture2D"
		picker.edited_resource = (terrain.get_meta(key) as Resource) if terrain.has_meta(key) else null
		picker.tooltip_text = tooltip
		picker.resource_changed.connect(func(resource: Resource) -> void:
			host.call("_set_feature_setting", terrain, key, resource)
		)
		parent.add_child(picker)


	func _add_water_normal_texture_control(parent: VBoxContainer, terrain: Node3D) -> void:
		var tooltip := "Optional custom seamless water normal map. Leave empty to use the generated default. NoiseTexture2D resources can be edited directly below."
		var label := Label.new()
		label.text = "Water Normal Texture"
		label.tooltip_text = tooltip
		parent.add_child(label)

		var picker := EditorResourcePicker.new()
		picker.base_type = "Texture2D"
		picker.edited_resource = (terrain.get_meta("_lte_river_normal_texture") as Resource) if terrain.has_meta("_lte_river_normal_texture") else null
		picker.tooltip_text = tooltip
		picker.resource_changed.connect(func(resource: Resource) -> void:
			host.call("_set_feature_setting_and_refresh", terrain, "_lte_river_normal_texture", resource)
		)
		parent.add_child(picker)

		var create_button := Button.new()
		create_button.text = "Create Editable Procedural Normal"
		create_button.tooltip_text = "Create a local NoiseTexture2D + FastNoiseLite normal map and expose its common water settings below."
		create_button.pressed.connect(func() -> void:
			host.call("_create_editable_water_normal", terrain)
		)
		parent.add_child(create_button)

		var resource := picker.edited_resource
		if not (resource is NoiseTexture2D):
			if resource != null:
				_add_help_text(parent, "The selected Texture2D is usable as-is. Inline controls are available when the selected resource is a NoiseTexture2D.")
			return

		var noise_texture := resource as NoiseTexture2D
		var editor := _add_foldout(parent, "NoiseTexture2D Settings", false)

		var seamless := CheckBox.new()
		seamless.text = "Seamless"
		seamless.button_pressed = noise_texture.seamless
		seamless.toggled.connect(func(enabled: bool) -> void:
			noise_texture.seamless = enabled
		)
		editor.add_child(seamless)

		var normal_map := CheckBox.new()
		normal_map.text = "As Normal Map"
		normal_map.button_pressed = noise_texture.as_normal_map
		normal_map.toggled.connect(func(enabled: bool) -> void:
			noise_texture.as_normal_map = enabled
		)
		editor.add_child(normal_map)

		_add_noise_texture_int_control(editor, noise_texture, "Width", "width", 32, 2048, 256, "Generated texture width.")
		_add_noise_texture_int_control(editor, noise_texture, "Height", "height", 32, 2048, 256, "Generated texture height.")

		var fast_noise := noise_texture.noise as FastNoiseLite
		if fast_noise == null:
			var add_noise := Button.new()
			add_noise.text = "Add FastNoiseLite"
			add_noise.pressed.connect(func() -> void:
				host.call("_ensure_fast_noise_on_water_texture", terrain, noise_texture)
			)
			editor.add_child(add_noise)
			return

		var noise_editor := _add_foldout(editor, "FastNoiseLite Settings", true)
		_add_fast_noise_float_control(noise_editor, fast_noise, "Frequency", "frequency", 0.001, 1.0, 0.001, "Noise scale. Lower values create broader waves.")
		_add_fast_noise_int_control(noise_editor, fast_noise, "Fractal Octaves", "fractal_octaves", 1, 10, "Number of fractal detail layers.")
		_add_fast_noise_int_control(noise_editor, fast_noise, "Seed", "seed", -2147483648, 2147483647, "Random noise seed.")

	func _add_noise_texture_int_control(parent: VBoxContainer, texture: NoiseTexture2D, label_text: String, property_name: String, min_value: int, max_value: int, default_value: int, tooltip: String) -> void:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = min_value
		spin.max_value = max_value
		spin.step = 1
		spin.value = int(texture.get(property_name)) if texture.get(property_name) != null else default_value
		spin.tooltip_text = tooltip
		spin.custom_minimum_size.x = 110.0
		spin.value_changed.connect(func(value: float) -> void:
			texture.set(property_name, int(value))
		)
		row.add_child(spin)
		parent.add_child(row)

	func _add_fast_noise_float_control(parent: VBoxContainer, noise: FastNoiseLite, label_text: String, property_name: String, min_value: float, max_value: float, step: float, tooltip: String) -> void:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = min_value
		spin.max_value = max_value
		spin.step = step
		spin.value = float(noise.get(property_name))
		spin.tooltip_text = tooltip
		spin.custom_minimum_size.x = 110.0
		spin.value_changed.connect(func(value: float) -> void:
			noise.set(property_name, value)
		)
		row.add_child(spin)
		parent.add_child(row)

	func _add_fast_noise_int_control(parent: VBoxContainer, noise: FastNoiseLite, label_text: String, property_name: String, min_value: int, max_value: int, tooltip: String) -> void:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)
		var spin := SpinBox.new()
		spin.min_value = min_value
		spin.max_value = max_value
		spin.step = 1
		spin.value = int(noise.get(property_name))
		spin.tooltip_text = tooltip
		spin.custom_minimum_size.x = 110.0
		spin.value_changed.connect(func(value: float) -> void:
			noise.set(property_name, int(value))
		)
		row.add_child(spin)
		parent.add_child(row)

	func _add_feature_checkbox(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, default_value: bool, tooltip: String) -> void:
		var check := CheckBox.new()
		check.text = label_text
		check.tooltip_text = tooltip
		check.button_pressed = bool(terrain.get_meta(key, default_value))
		check.toggled.connect(func(enabled: bool) -> void:
			host.call("_set_feature_setting", terrain, key, enabled)
		)
		parent.add_child(check)

	func _add_generator_float_control(
		parent: VBoxContainer, terrain: Node3D, label_text: String, key: String,
		min_value: float, max_value: float, step: float, default_value: float, tooltip: String
	) -> void:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var spin := SpinBox.new()
		spin.min_value = min_value
		spin.max_value = max_value
		spin.step = step
		spin.value = float(terrain.get_meta(key, default_value))
		spin.tooltip_text = tooltip
		spin.custom_minimum_size.x = 110.0
		spin.value_changed.connect(func(value: float) -> void:
			host.call("_set_generator_setting", terrain, key, value)
		)
		row.add_child(spin)
		parent.add_child(row)

	func _add_generator_color_control(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, default_value: Color, tooltip: String) -> void:
		var row := HBoxContainer.new()
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(label)

		var picker := ColorPickerButton.new()
		picker.color = terrain.get_meta(key, default_value)
		picker.tooltip_text = tooltip
		picker.custom_minimum_size = Vector2(110.0, 28.0)
		picker.color_changed.connect(func(value: Color) -> void:
			host.call("_set_generator_setting", terrain, key, value)
		)
		row.add_child(picker)
		parent.add_child(row)

	func _add_generator_style_section(parent: VBoxContainer, terrain: Node3D, title: String, prefix: String) -> void:
		var section := _add_foldout(parent, title, false)

		var top_color_key := "_lte_generator_%s_top_color" % prefix
		var cliff_color_key := "_lte_generator_%s_cliff_color" % prefix
		var top_texture_key := "_lte_generator_%s_top_texture" % prefix
		var cliff_texture_key := "_lte_generator_%s_cliff_texture" % prefix
		var top_tile_key := "_lte_generator_%s_top_tile_size" % prefix
		var cliff_tile_key := "_lte_generator_%s_cliff_tile_size" % prefix

		_add_generator_color_control(section, terrain, "Top Color", top_color_key, Color(0.44, 0.69, 0.20), "Top-face fallback color for this generated map class.")
		_add_generator_color_control(section, terrain, "Side Color", cliff_color_key, Color(0.45, 0.25, 0.13), "Side/cliff fallback color for this generated map class.")
		_add_generator_texture_control(section, terrain, "Top Texture", top_texture_key, "Optional top texture for this generated map class.")
		_add_generator_float_control(section, terrain, "Top Texture Tile Size", top_tile_key, 0.1, 64.0, 0.1, 4.0, "World units per top-texture repeat.")
		_add_generator_texture_control(section, terrain, "Side Texture", cliff_texture_key, "Optional side/cliff texture for this generated map class.")
		_add_generator_float_control(section, terrain, "Side Texture Tile Size", cliff_tile_key, 0.1, 64.0, 0.1, 4.0, "World units per side-texture repeat.")

	func _add_generator_texture_control(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, tooltip: String) -> void:
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		parent.add_child(label)

		var picker := EditorResourcePicker.new()
		picker.base_type = "Texture2D"
		picker.edited_resource = (terrain.get_meta(key) as Resource) if terrain.has_meta(key) else null
		picker.tooltip_text = tooltip
		picker.resource_changed.connect(func(resource: Resource) -> void:
			host.call("_set_generator_setting", terrain, key, resource)
		)
		parent.add_child(picker)

	func _add_texture_control(parent: VBoxContainer, terrain: Node3D, label_text: String, key: String, tooltip: String) -> void:
		var label := Label.new()
		label.text = label_text
		label.tooltip_text = tooltip
		parent.add_child(label)

		var picker := EditorResourcePicker.new()
		picker.base_type = "Texture2D"
		picker.edited_resource = (terrain.get_meta(key) as Resource) if terrain.has_meta(key) else null
		picker.tooltip_text = tooltip
		picker.resource_changed.connect(func(resource: Resource) -> void:
			host.call("_set_paint_setting", terrain, key, resource)
		)
		parent.add_child(picker)

# -----------------------------------------------------------------------------
# Constants
# -----------------------------------------------------------------------------

const META_MARKER := "_lowpoly_terrain"
const META_RESOLUTION := "_lte_resolution"
const META_WORLD_SIZE := "_lte_world_size"
const META_MASK := "_lte_mask"
const META_HEIGHTS := "_lte_heights"
const META_ROADS := "_lte_roads"
const META_RIVERS := "_lte_rivers"
const META_LEVEL_PATH := "_lte_level_path"
const META_BASE_Y := "_lte_base_y"
const META_HEIGHT_MIN := "_lte_height_min"
const META_HEIGHT_MAX := "_lte_height_max"
const META_TOP_Y_OFFSET := "_lte_top_y_offset"
const META_CLIFF_Y_OFFSET := "_lte_cliff_y_offset"
const META_FEATURE_Y_OFFSET := "_lte_feature_y_offset"
const META_DOUBLE_SIDED := "_lte_double_sided"
const META_TOP_NORMAL_UP_BIAS := "_lte_top_normal_up_bias"
const META_WINDING_VERSION := "_lte_winding_version"
const META_STYLE_PALETTE := "_lte_style_palette"
const META_CELL_STYLES := "_lte_cell_styles"
const META_BRUSH_TOP_COLOR := "_lte_brush_top_color"
const META_BRUSH_CLIFF_COLOR := "_lte_brush_cliff_color"
const META_BRUSH_TOP_TEXTURE := "_lte_brush_top_texture"
const META_BRUSH_CLIFF_TEXTURE := "_lte_brush_cliff_texture"
const META_BRUSH_TOP_TILE_SIZE := "_lte_brush_top_tile_size"
const META_BRUSH_CLIFF_TILE_SIZE := "_lte_brush_cliff_tile_size"
const META_COLLISION_ENABLED := "_lte_collision_enabled"
const META_COLLISION_LAYER := "_lte_collision_layer"
const META_AUTO_EXPAND := "_lte_auto_expand"
const META_EXPAND_CHUNK := "_lte_expand_chunk"
const META_MAX_RESOLUTION := "_lte_max_resolution"
const META_CELL_ACTIVE := "_lte_cell_active"
const META_GENERATOR_IMAGE := "_lte_generator_image"
const META_GENERATOR_RAISE_HEIGHT := "_lte_generator_raise_height"
const META_GENERATOR_LOWER_DEPTH := "_lte_generator_lower_depth"
const META_GENERATOR_COLOR_TOLERANCE := "_lte_generator_color_tolerance"
const META_GENERATOR_CLEAR_FEATURES := "_lte_generator_clear_features"
const META_GENERATOR_USE_SINGLE_STYLE := "_lte_generator_use_single_style"
const META_GENERATOR_SMOOTHNESS := "_lte_generator_smoothness"

const META_GENERATOR_GREEN_TOP_COLOR := "_lte_generator_green_top_color"
const META_GENERATOR_GREEN_CLIFF_COLOR := "_lte_generator_green_cliff_color"
const META_GENERATOR_GREEN_TOP_TEXTURE := "_lte_generator_green_top_texture"
const META_GENERATOR_GREEN_CLIFF_TEXTURE := "_lte_generator_green_cliff_texture"
const META_GENERATOR_GREEN_TOP_TILE_SIZE := "_lte_generator_green_top_tile_size"
const META_GENERATOR_GREEN_CLIFF_TILE_SIZE := "_lte_generator_green_cliff_tile_size"

const META_GENERATOR_RED_TOP_COLOR := "_lte_generator_red_top_color"
const META_GENERATOR_RED_CLIFF_COLOR := "_lte_generator_red_cliff_color"
const META_GENERATOR_RED_TOP_TEXTURE := "_lte_generator_red_top_texture"
const META_GENERATOR_RED_CLIFF_TEXTURE := "_lte_generator_red_cliff_texture"
const META_GENERATOR_RED_TOP_TILE_SIZE := "_lte_generator_red_top_tile_size"
const META_GENERATOR_RED_CLIFF_TILE_SIZE := "_lte_generator_red_cliff_tile_size"

const META_GENERATOR_BLUE_TOP_COLOR := "_lte_generator_blue_top_color"
const META_GENERATOR_BLUE_CLIFF_COLOR := "_lte_generator_blue_cliff_color"
const META_GENERATOR_BLUE_TOP_TEXTURE := "_lte_generator_blue_top_texture"
const META_GENERATOR_BLUE_CLIFF_TEXTURE := "_lte_generator_blue_cliff_texture"
const META_GENERATOR_BLUE_TOP_TILE_SIZE := "_lte_generator_blue_top_tile_size"
const META_GENERATOR_BLUE_CLIFF_TILE_SIZE := "_lte_generator_blue_cliff_tile_size"
const META_ROAD_WIDTH := "_lte_road_width"
const META_ROAD_Y_OFFSET := "_lte_road_y_offset"
const META_ROAD_COLOR := "_lte_road_color"
const META_ROAD_TEXTURE := "_lte_road_texture"
const META_ROAD_TILE_SIZE := "_lte_road_tile_size"
const META_ROAD_COLLISION := "_lte_road_collision"
const META_RIVER_WIDTH := "_lte_river_width"
const META_RIVER_DEPTH := "_lte_river_depth"
const META_RIVER_SURFACE_DROP := "_lte_river_surface_drop"
const META_RIVER_COLOR := "_lte_river_color"
const META_RIVER_TEXTURE := "_lte_river_texture"
const META_RIVER_NORMAL_TEXTURE := "_lte_river_normal_texture"
const META_RIVER_TILE_SIZE := "_lte_river_tile_size"
const META_RIVER_ROUGHNESS := "_lte_river_roughness"
const META_RIVER_NORMAL_STRENGTH := "_lte_river_normal_strength"
const META_RIVER_REFRACTION := "_lte_river_refraction"
const META_RIVER_FLOW_SPEED := "_lte_river_flow_speed"
const META_RIVER_FLOW_ANGLE := "_lte_river_flow_angle"
const META_RIVER_COLLISION := "_lte_river_collision"
const CURRENT_WINDING_VERSION := 2

const GENERATED_MESH_NAME := "_GeneratedTerrainMesh"
const GENERATED_CHUNKS_NAME := "_GeneratedTerrainChunks"
const GENERATED_PREVIEW_MESH_NAME := "_GeneratedTerrainFeaturePreview"
const TERRAIN_CHUNK_CELLS := 32
const GENERATED_COLLISION_BODY_NAME := "_GeneratedTerrainCollision"
const GENERATED_COLLISION_SHAPE_NAME := "_GeneratedTerrainCollisionShape"

const DEFAULT_RESOLUTION := 48
const DEFAULT_WORLD_SIZE := 48.0
const DEFAULT_BASE_Y := -3.0

const HEIGHT_MIN := -3.0
const HEIGHT_MAX := 8.0

const ROAD_WIDTH := 2.6
const ROAD_SAMPLE_SPACING := 0.45
const ROAD_JUNCTION_RADIUS_SCALE := 0.62
const ROAD_UNION_CELL_SIZE := 0.45
const ROAD_UNION_EDGE_PADDING := 0.32
const RIVER_WIDTH := 3.3
const RIVER_DEPTH := 0.65

const FEATURE_SAMPLE_DISTANCE := 0.65

const LEVEL_DIRECTORY := "res://terrain_levels"

enum ToolMode {
	NONE, PAINT, ERASE, RAISE, LOWER, FLATTEN, SMOOTH, ROAD, RIVER
}

# -----------------------------------------------------------------------------
# Editor state
# -----------------------------------------------------------------------------

var _active_terrain: Node3D = null
var _tool_mode: ToolMode = ToolMode.NONE
var _brush_radius := 3.0
var _brush_strength := 1.0
var _stroke_active := false
var _stroke_before: Dictionary = {}
var _flatten_height := 0.0
var _feature_points: Array[Vector2] = []
var _erase_feature_stroke := false
var _stroke_dirty_rect := Rect2()
var _stroke_has_dirty_rect := false
var _max_expand_warned_this_stroke := false

# Runtime/editor caches. These are derived data and deliberately are not saved
# into terrain metadata or Undo snapshots.
var _river_carve_cache: Dictionary = {}
var _feature_collision_cache: Dictionary = {}

var _toolbar: HBoxContainer
var _level_menu: MenuButton
var _tool_buttons: Dictionary = {}
var _brush_radius_spin: SpinBox
var _brush_strength_spin: SpinBox
var _status_label: Label
var _save_dialog: EditorFileDialog
var _duplicate_dialog: EditorFileDialog
var _delete_dialog: ConfirmationDialog

var _top_material: StandardMaterial3D
var _cliff_material: StandardMaterial3D
var _road_material: StandardMaterial3D
var _river_material: StandardMaterial3D
var _generated_water_normal: Texture2D = null
var _last_tuning_signature := ""
var _terrain_inspector_plugin: EditorInspectorPlugin

# =============================================================================
# PLUGIN LIFECYCLE
# =============================================================================

func _enter_tree() -> void:
	_create_materials()
	_terrain_inspector_plugin = TerrainInspectorPlugin.new(self)
	add_inspector_plugin(_terrain_inspector_plugin)
	_create_toolbar()
	_create_dialogs()
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
	_ensure_level_directory()
	set_process(true)
	_update_toolbar_state()

func _exit_tree() -> void:
	if _terrain_inspector_plugin:
		remove_inspector_plugin(_terrain_inspector_plugin)
		_terrain_inspector_plugin = null
	if _toolbar:
		remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, _toolbar)
		_toolbar.queue_free()
	if _save_dialog:
		_save_dialog.queue_free()
	if _duplicate_dialog:
		_duplicate_dialog.queue_free()
	if _delete_dialog:
		_delete_dialog.queue_free()

func _handles(object: Object) -> bool:
	# Return true for ANY Node3D so the top menu appears in 3D scenes.
	# This ensures the "New Terrain" button is always accessible.
	return object is Node3D

func _edit(object: Object) -> void:
	# Only set as active terrain if it actually has the meta marker
	if object is Node3D and object.has_meta(META_MARKER) and bool(object.get_meta(META_MARKER)):
		_active_terrain = object
		_install_terrain_inspector_properties(_active_terrain)
		_sync_material_cull_mode(_active_terrain)
		# Rebuild immediately when the terrain is selected. This is important after
		# plugin upgrades because an existing MeshInstance3D can still contain the
		# ArrayMesh generated by the previous winding/normal implementation.
		_generate_terrain_mesh(_active_terrain)
		_last_tuning_signature = _terrain_tuning_signature(_active_terrain)
	else:
		_active_terrain = null
		
	_update_toolbar_state()

func _make_visible(visible: bool) -> void:
	if _toolbar:
		_toolbar.visible = visible

func _process(_delta: float) -> void:
	if not is_instance_valid(_active_terrain):
		_last_tuning_signature = ""
		return

	var signature := _terrain_tuning_signature(_active_terrain)
	if signature != _last_tuning_signature:
		_last_tuning_signature = signature
		_generate_terrain_mesh(_active_terrain)

# =============================================================================
# TOOLBAR
# =============================================================================

func _create_toolbar() -> void:
	# CONTAINER_SPATIAL_EDITOR_MENU expects a normal toolbar-like Control.
	# A ScrollContainer here can collapse to a tiny viewport in the Godot editor,
	# so keep the root as an HBoxContainer and reduce width with a Level menu.
	_toolbar = HBoxContainer.new()
	_toolbar.name = "LowpolyTerrainToolbar"
	_toolbar.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN

	var new_button := Button.new()
	new_button.text = "New Terrain"
	new_button.tooltip_text = "Create a new editable low-poly terrain in the current scene."
	new_button.pressed.connect(_create_new_terrain)
	_toolbar.add_child(new_button)

	_add_separator()

	_add_tool_button("Paint", ToolMode.PAINT)
	_add_tool_button("Erase", ToolMode.ERASE)
	_add_separator()
	_add_tool_button("Raise", ToolMode.RAISE)
	_add_tool_button("Lower", ToolMode.LOWER)
	_add_tool_button("Flatten", ToolMode.FLATTEN)
	_add_tool_button("Smooth", ToolMode.SMOOTH)
	_add_separator()
	_add_tool_button("Road", ToolMode.ROAD)
	_add_tool_button("River", ToolMode.RIVER)
	_add_separator()

	var radius_label := Label.new()
	radius_label.text = "Size"
	_toolbar.add_child(radius_label)

	_brush_radius_spin = SpinBox.new()
	_brush_radius_spin.min_value = 0.5
	_brush_radius_spin.max_value = 12.0
	_brush_radius_spin.step = 0.25
	_brush_radius_spin.value = _brush_radius
	_brush_radius_spin.custom_minimum_size.x = 62.0
	_brush_radius_spin.value_changed.connect(func(value: float) -> void: _brush_radius = value)
	_toolbar.add_child(_brush_radius_spin)

	var strength_label := Label.new()
	strength_label.text = "Str"
	strength_label.tooltip_text = "Brush Strength"
	_toolbar.add_child(strength_label)

	_brush_strength_spin = SpinBox.new()
	_brush_strength_spin.min_value = 0.05
	_brush_strength_spin.max_value = 4.0
	_brush_strength_spin.step = 0.05
	_brush_strength_spin.value = _brush_strength
	_brush_strength_spin.custom_minimum_size.x = 62.0
	_brush_strength_spin.value_changed.connect(func(value: float) -> void: _brush_strength = value)
	_toolbar.add_child(_brush_strength_spin)

	_add_separator()

	var undo_button := Button.new()
	undo_button.text = "Undo"
	undo_button.pressed.connect(_toolbar_undo)
	_toolbar.add_child(undo_button)

	var redo_button := Button.new()
	redo_button.text = "Redo"
	redo_button.pressed.connect(_toolbar_redo)
	_toolbar.add_child(redo_button)

	_add_separator()

	# File/level operations are grouped into one compact menu. This avoids making
	# the 3D toolbar impose an excessive minimum width on smaller editor layouts.
	_level_menu = MenuButton.new()
	_level_menu.text = "Level"
	_level_menu.tooltip_text = "Save, duplicate, or delete the selected terrain level."
	var popup := _level_menu.get_popup()
	popup.add_item("Save Level", 0)
	popup.add_item("Duplicate", 1)
	popup.add_separator()
	popup.add_item("Delete", 2)
	popup.id_pressed.connect(_on_level_menu_pressed)
	_toolbar.add_child(_level_menu)

	_add_separator()

	_status_label = Label.new()
	_status_label.text = "No terrain"
	_status_label.clip_text = true
	_status_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_status_label.custom_minimum_size.x = 118.0
	_status_label.size_flags_horizontal = Control.SIZE_SHRINK_END
	_status_label.tooltip_text = _status_label.text
	_toolbar.add_child(_status_label)

func _get_active_undo_history() -> UndoRedo:
	var manager := get_undo_redo()
	var context: Object = _active_terrain if is_instance_valid(_active_terrain) else get_editor_interface().get_edited_scene_root()
	if context == null:
		return null
	var history_id: int = manager.get_object_history_id(context)
	return manager.get_history_undo_redo(history_id)

func _toolbar_undo() -> void:
	var history := _get_active_undo_history()
	if history != null and history.has_undo():
		history.undo()

func _toolbar_redo() -> void:
	var history := _get_active_undo_history()
	if history != null and history.has_redo():
		history.redo()

func _on_level_menu_pressed(id: int) -> void:
	match id:
		0: _request_save_level()
		1: _request_duplicate_level()
		2: _request_delete_level()

func _add_separator() -> void:
	if _toolbar:
		_toolbar.add_child(VSeparator.new())

func _add_tool_button(label: String, mode: ToolMode) -> void:
	var button := Button.new()
	button.text = label
	button.toggle_mode = true
	button.tooltip_text = "Erase terrain, or erase Road/River sections when the erase stroke starts over a feature." if mode == ToolMode.ERASE else label

	# Manage exclusivity ourselves. ButtonGroup.toggled can emit the old button's
	# "off" signal while a different button is being pressed; the old handler then
	# clears the newly selected tool and produces the two-click switching behavior.
	# Manual state updates give the desired semantics:
	#   * click another tool -> switch immediately
	#   * click the active tool -> deselect it
	button.pressed.connect(func() -> void:
		if _tool_mode == mode:
			_set_tool(ToolMode.NONE)
		else:
			_set_tool(mode)
	)

	_tool_buttons[mode] = button
	_toolbar.add_child(button)

func _set_tool(mode: ToolMode) -> void:
	_tool_mode = mode
	for key in _tool_buttons:
		var button: Button = _tool_buttons[key]
		button.set_pressed_no_signal(key == mode)
	_update_toolbar_state()

func _update_toolbar_state() -> void:
	if not _toolbar:
		return

	var has_terrain := is_instance_valid(_active_terrain)
	for mode in _tool_buttons:
		var button: Button = _tool_buttons[mode]
		button.disabled = not has_terrain

	if _brush_radius_spin: _brush_radius_spin.editable = has_terrain
	if _brush_strength_spin: _brush_strength_spin.editable = has_terrain
	if _level_menu: _level_menu.disabled = not has_terrain

	if _status_label:
		if not has_terrain:
			_status_label.text = "No terrain"
		else:
			_status_label.text = "%s | %s" % [_active_terrain.name, _tool_name(_tool_mode)]
		_status_label.tooltip_text = _status_label.text

func _tool_name(mode: ToolMode) -> String:
	match mode:
		ToolMode.PAINT: return "Paint"
		ToolMode.ERASE: return "Erase"
		ToolMode.RAISE: return "Raise"
		ToolMode.LOWER: return "Lower"
		ToolMode.FLATTEN: return "Flatten"
		ToolMode.SMOOTH: return "Smooth"
		ToolMode.ROAD: return "Road"
		ToolMode.RIVER: return "River"
		_: return "Select"

# =============================================================================
# TERRAIN CREATION
# =============================================================================

func _create_new_terrain() -> void:
	var scene_root := get_editor_interface().get_edited_scene_root()
	if not scene_root:
		push_warning("Lowpoly Terrain Editor: create or open a scene before creating terrain.")
		return

	var terrain := Node3D.new()
	terrain.name = "LowpolyTerrain"
	scene_root.add_child(terrain)
	terrain.owner = scene_root

	_initialize_terrain_data(terrain)

	var mesh_instance := MeshInstance3D.new()
	mesh_instance.name = GENERATED_MESH_NAME
	terrain.add_child(mesh_instance)
	mesh_instance.owner = scene_root

	_generate_terrain_mesh(terrain)
	_last_tuning_signature = _terrain_tuning_signature(terrain)

	var undo_redo := get_undo_redo()
	undo_redo.create_action("Create Lowpoly Terrain", UndoRedo.MERGE_DISABLE, terrain)
	undo_redo.add_do_reference(terrain)
	undo_redo.add_undo_method(scene_root, "remove_child", terrain)
	undo_redo.add_do_method(scene_root, "add_child", terrain)
	undo_redo.commit_action(false)

	var selection := get_editor_interface().get_selection()
	selection.clear()
	selection.add_node(terrain)

	_active_terrain = terrain
	_set_tool(ToolMode.PAINT)
	_update_toolbar_state()

func _initialize_terrain_data(terrain: Node3D) -> void:
	var resolution := DEFAULT_RESOLUTION
	
	var mask := PackedFloat32Array()
	mask.resize(resolution * resolution)
	mask.fill(0.0)

	var heights := PackedFloat32Array()
	heights.resize(resolution * resolution)
	heights.fill(0.0)

	terrain.set_meta(META_MARKER, true)
	terrain.set_meta(META_RESOLUTION, resolution)
	terrain.set_meta(META_WORLD_SIZE, DEFAULT_WORLD_SIZE)
	terrain.set_meta(META_MASK, mask)
	terrain.set_meta(META_HEIGHTS, heights)
	terrain.set_meta(META_ROADS, [])
	terrain.set_meta(META_RIVERS, [])
	terrain.set_meta(META_LEVEL_PATH, "")
	terrain.set_meta(META_BASE_Y, DEFAULT_BASE_Y)
	terrain.set_meta(META_HEIGHT_MIN, HEIGHT_MIN)
	terrain.set_meta(META_HEIGHT_MAX, HEIGHT_MAX)
	terrain.set_meta(META_TOP_Y_OFFSET, 0.0)
	terrain.set_meta(META_CLIFF_Y_OFFSET, 0.0)
	terrain.set_meta(META_FEATURE_Y_OFFSET, 0.0)
	terrain.set_meta(META_DOUBLE_SIDED, false)
	terrain.set_meta(META_TOP_NORMAL_UP_BIAS, 0.0)
	terrain.set_meta(META_BRUSH_TOP_COLOR, Color(0.44, 0.69, 0.20))
	terrain.set_meta(META_BRUSH_CLIFF_COLOR, Color(0.45, 0.25, 0.13))
	terrain.set_meta(META_BRUSH_TOP_TEXTURE, null)
	terrain.set_meta(META_BRUSH_CLIFF_TEXTURE, null)
	terrain.set_meta(META_BRUSH_TOP_TILE_SIZE, 4.0)
	terrain.set_meta(META_BRUSH_CLIFF_TILE_SIZE, 4.0)
	terrain.set_meta(META_COLLISION_ENABLED, false)
	terrain.set_meta(META_COLLISION_LAYER, 1)
	terrain.set_meta(META_AUTO_EXPAND, true)
	terrain.set_meta(META_EXPAND_CHUNK, 8)
	terrain.set_meta(META_MAX_RESOLUTION, 256)
	terrain.set_meta(META_GENERATOR_RAISE_HEIGHT, 2.0)
	terrain.set_meta(META_GENERATOR_LOWER_DEPTH, 1.0)
	terrain.set_meta(META_GENERATOR_COLOR_TOLERANCE, 0.2)
	terrain.set_meta(META_GENERATOR_SMOOTHNESS, 0.0)
	terrain.set_meta(META_GENERATOR_CLEAR_FEATURES, true)
	terrain.set_meta(META_GENERATOR_USE_SINGLE_STYLE, true)
	_copy_current_paint_to_generator_styles(terrain)
	terrain.set_meta(META_ROAD_WIDTH, ROAD_WIDTH)
	terrain.set_meta(META_ROAD_Y_OFFSET, 0.035)
	terrain.set_meta(META_ROAD_COLOR, Color(0.76, 0.56, 0.31))
	terrain.set_meta(META_ROAD_TILE_SIZE, 4.0)
	terrain.set_meta(META_ROAD_COLLISION, true)
	terrain.set_meta(META_RIVER_WIDTH, RIVER_WIDTH)
	terrain.set_meta(META_RIVER_DEPTH, RIVER_DEPTH)
	terrain.set_meta(META_RIVER_SURFACE_DROP, 0.15)
	terrain.set_meta(META_RIVER_COLOR, Color(0.12, 0.38, 0.55, 0.72))
	terrain.set_meta(META_RIVER_TILE_SIZE, 6.0)
	terrain.set_meta(META_RIVER_ROUGHNESS, 0.18)
	terrain.set_meta(META_RIVER_NORMAL_STRENGTH, 0.8)
	terrain.set_meta(META_RIVER_REFRACTION, 0.012)
	terrain.set_meta(META_RIVER_FLOW_SPEED, 0.03)
	terrain.set_meta(META_RIVER_FLOW_ANGLE, 32.211)
	terrain.set_meta(META_RIVER_COLLISION, false)
	terrain.set_meta(META_STYLE_PALETTE, [_make_default_style()])
	var cell_styles := PackedInt32Array()
	cell_styles.resize((resolution - 1) * (resolution - 1))
	cell_styles.fill(-1)
	terrain.set_meta(META_CELL_STYLES, cell_styles)
	var cell_active := PackedByteArray()
	cell_active.resize((resolution - 1) * (resolution - 1))
	cell_active.fill(0)
	terrain.set_meta(META_CELL_ACTIVE, cell_active)
	terrain.set_meta(META_WINDING_VERSION, CURRENT_WINDING_VERSION)
	_install_terrain_inspector_properties(terrain)

# =============================================================================
# VIEWPORT INPUT
# =============================================================================

func _forward_3d_gui_input(viewport_camera: Camera3D, event: InputEvent) -> int:
	if not is_instance_valid(_active_terrain) or _tool_mode == ToolMode.NONE:
		return EditorPlugin.AFTER_GUI_INPUT_PASS

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			var local_hit := _mouse_to_local_terrain(viewport_camera, event.position)
			if local_hit == null:
				return EditorPlugin.AFTER_GUI_INPUT_PASS
			_begin_stroke(local_hit)
			return EditorPlugin.AFTER_GUI_INPUT_STOP
		elif _stroke_active:
			_end_stroke()
			return EditorPlugin.AFTER_GUI_INPUT_STOP

	if event is InputEventMouseMotion and _stroke_active:
		var local_hit := _mouse_to_local_terrain(viewport_camera, event.position)
		if local_hit != null:
			_continue_stroke(local_hit)
		return EditorPlugin.AFTER_GUI_INPUT_STOP

	return EditorPlugin.AFTER_GUI_INPUT_PASS

func _mouse_to_local_terrain(camera: Camera3D, screen_position: Vector2) -> Variant:
	if not is_instance_valid(_active_terrain):
		return null

	var ray_origin := camera.project_ray_origin(screen_position)
	var ray_direction := camera.project_ray_normal(screen_position)
	var terrain_origin := _active_terrain.global_position
	var plane_normal := _active_terrain.global_transform.basis.y.normalized()
	
	var plane := Plane(plane_normal, plane_normal.dot(terrain_origin))
	var world_hit := plane.intersects_ray(ray_origin, ray_direction)
	
	if world_hit == null:
		return null
	return _active_terrain.to_local(world_hit)

# =============================================================================
# STROKES
# =============================================================================

func _begin_stroke(local_position: Vector3) -> void:
	_stroke_active = true
	_stroke_before = _capture_snapshot(_active_terrain)
	_erase_feature_stroke = false
	_stroke_dirty_rect = Rect2()
	_stroke_has_dirty_rect = false
	_max_expand_warned_this_stroke = false

	if _tool_mode == ToolMode.ERASE:
		_erase_feature_stroke = _has_feature_at(_active_terrain, Vector2(local_position.x, local_position.z), _brush_radius)
		if _erase_feature_stroke:
			_erase_features_at(_active_terrain, Vector2(local_position.x, local_position.z), _brush_radius)
			# Feature erasing can change river carving, so use a full rebuild here.
			_generate_terrain_mesh(_active_terrain)
			return

	if _tool_mode == ToolMode.ROAD or _tool_mode == ToolMode.RIVER:
		_feature_points.clear()
		_feature_points.append(Vector2(local_position.x, local_position.z))
		return

	if _tool_mode == ToolMode.FLATTEN:
		_flatten_height = _sample_base_height(_active_terrain, Vector2(local_position.x, local_position.z))

	_apply_brush(local_position)

func _continue_stroke(local_position: Vector3) -> void:
	if _tool_mode == ToolMode.ERASE and _erase_feature_stroke:
		_erase_features_at(_active_terrain, Vector2(local_position.x, local_position.z), _brush_radius)
		_generate_terrain_mesh(_active_terrain)
		return

	if _tool_mode == ToolMode.ROAD or _tool_mode == ToolMode.RIVER:
		var point := Vector2(local_position.x, local_position.z)
		if _feature_points.is_empty() or _feature_points[-1].distance_to(point) >= FEATURE_SAMPLE_DISTANCE:
			_feature_points.append(point)
			# Preview is isolated from committed roads/rivers, so existing features
			# are not regenerated on every mouse sample.
			_generate_feature_preview_mesh(_active_terrain, _preview_feature())
		return
	_apply_brush(local_position)

func _end_stroke() -> void:
	if not _stroke_active:
		return

	if _tool_mode == ToolMode.ROAD:
		_commit_feature(META_ROADS)
	elif _tool_mode == ToolMode.RIVER:
		_commit_feature(META_RIVERS)

	var after := _capture_snapshot(_active_terrain)
	if not _snapshots_equal(_stroke_before, after):
		var undo_redo := get_undo_redo()
		undo_redo.create_action("Lowpoly Terrain: %s" % _tool_name(_tool_mode), UndoRedo.MERGE_DISABLE, _active_terrain)
		undo_redo.add_do_method(self, "_restore_snapshot", _active_terrain, after)
		undo_redo.add_undo_method(self, "_restore_snapshot", _active_terrain, _stroke_before)
		undo_redo.commit_action(false)

	_feature_points.clear()
	_stroke_before = {}
	_stroke_active = false

	var feature_erase_finished := _erase_feature_stroke
	_erase_feature_stroke = false

	_clear_feature_preview_mesh(_active_terrain)

	if _tool_mode == ToolMode.ROAD or _tool_mode == ToolMode.RIVER or feature_erase_finished:
		# Feature edits can change river carving, so refresh the derived carve cache
		# and affected terrain once when the stroke is committed.
		_generate_terrain_mesh(_active_terrain)
	else:
		# Ordinary terrain editing does not rebuild roads/rivers unless the stroke
		# actually overlaps one. Unrelated chunks therefore stay cheap even after
		# many features have been added to the map.
		var feature_faces: PackedVector3Array
		if _stroke_has_dirty_rect and _features_intersect_rect(_active_terrain, _stroke_dirty_rect):
			feature_faces = _generate_feature_mesh(_active_terrain)
		else:
			feature_faces = _get_cached_feature_collision_faces(_active_terrain)
		_rebuild_terrain_collision_from_chunks(_active_terrain, feature_faces)

func _commit_feature(meta_key: String) -> void:
	if _feature_points.size() < 2:
		return
	var features: Array = _active_terrain.get_meta(meta_key, []).duplicate(true)
	var feature := _current_feature_style("road" if meta_key == META_ROADS else "river")
	feature["points"] = _feature_points.duplicate()
	features.append(feature)
	_active_terrain.set_meta(meta_key, features)

func _preview_feature() -> Dictionary:
	if _feature_points.size() < 2:
		return {}
	var feature_type := "road" if _tool_mode == ToolMode.ROAD else "river"
	var feature := _current_feature_style(feature_type)
	feature["type"] = feature_type
	feature["preview"] = true
	feature["points"] = _feature_points.duplicate()
	return feature

func _current_feature_style(feature_type: String) -> Dictionary:
	if feature_type == "road":
		return {
			"width": float(_active_terrain.get_meta(META_ROAD_WIDTH, ROAD_WIDTH)),
			"y_offset": float(_active_terrain.get_meta(META_ROAD_Y_OFFSET, 0.035)),
			"color": _active_terrain.get_meta(META_ROAD_COLOR, Color(0.76, 0.56, 0.31)),
			"texture": _get_optional_meta(_active_terrain, META_ROAD_TEXTURE) as Texture2D,
			"tile_size": float(_active_terrain.get_meta(META_ROAD_TILE_SIZE, 4.0)),
			"collision": bool(_active_terrain.get_meta(META_ROAD_COLLISION, true)),
		}
	return {
		"width": float(_active_terrain.get_meta(META_RIVER_WIDTH, RIVER_WIDTH)),
		"depth": float(_active_terrain.get_meta(META_RIVER_DEPTH, RIVER_DEPTH)),
		"surface_drop": float(_active_terrain.get_meta(META_RIVER_SURFACE_DROP, 0.15)),
		"color": _active_terrain.get_meta(META_RIVER_COLOR, Color(0.12, 0.38, 0.55, 0.72)),
		"texture": _get_optional_meta(_active_terrain, META_RIVER_TEXTURE) as Texture2D,
		"normal_texture": _get_optional_meta(_active_terrain, META_RIVER_NORMAL_TEXTURE) as Texture2D,
		"tile_size": float(_active_terrain.get_meta(META_RIVER_TILE_SIZE, 6.0)),
		"roughness": float(_active_terrain.get_meta(META_RIVER_ROUGHNESS, 0.18)),
		"normal_strength": float(_active_terrain.get_meta(META_RIVER_NORMAL_STRENGTH, 0.8)),
		"refraction": float(_active_terrain.get_meta(META_RIVER_REFRACTION, 0.012)),
		"flow_speed": float(_active_terrain.get_meta(META_RIVER_FLOW_SPEED, 0.03)),
		"flow_angle": float(_active_terrain.get_meta(META_RIVER_FLOW_ANGLE, 32.211)),
		"collision": bool(_active_terrain.get_meta(META_RIVER_COLLISION, false)),
	}

# =============================================================================
# FEATURE ERASING
# =============================================================================

func _has_feature_at(terrain: Node3D, point: Vector2, brush_radius: float) -> bool:
	for road in terrain.get_meta(META_ROADS, []):
		var points = road.get("points", [])
		var half_width: float = float(road.get("width", ROAD_WIDTH)) * 0.5
		if _distance_to_polyline(point, points) <= brush_radius + half_width:
			return true

	for river in terrain.get_meta(META_RIVERS, []):
		var points = river.get("points", [])
		var half_width: float = float(river.get("width", RIVER_WIDTH)) * 0.5
		if _distance_to_polyline(point, points) <= brush_radius + half_width:
			return true

	return false

func _erase_features_at(terrain: Node3D, point: Vector2, brush_radius: float) -> bool:
	var changed := false

	var road_result := _erase_feature_segments(
		terrain.get_meta(META_ROADS, []),
		point,
		brush_radius,
		ROAD_WIDTH
	)
	if bool(road_result["changed"]):
		terrain.set_meta(META_ROADS, road_result["features"])
		changed = true

	var river_result := _erase_feature_segments(
		terrain.get_meta(META_RIVERS, []),
		point,
		brush_radius,
		RIVER_WIDTH
	)
	if bool(river_result["changed"]):
		terrain.set_meta(META_RIVERS, river_result["features"])
		changed = true

	return changed

func _erase_feature_segments(features: Array, point: Vector2, brush_radius: float, default_width: float) -> Dictionary:
	var output: Array = []
	var any_changed := false

	for source_feature in features:
		var feature: Dictionary = source_feature
		var points: Array = feature.get("points", [])
		if points.size() < 2:
			output.append(feature.duplicate(true))
			continue

		var erase_distance: float = brush_radius + float(feature.get("width", default_width)) * 0.5
		var feature_changed := false
		var fragments: Array = []
		var run: Array[Vector2] = []

		for raw_point in points:
			var path_point: Vector2 = raw_point
			if path_point.distance_to(point) <= erase_distance:
				feature_changed = true
				if run.size() >= 2:
					var fragment: Dictionary = feature.duplicate(true)
					fragment["points"] = run.duplicate()
					fragments.append(fragment)
				run.clear()
			else:
				run.append(path_point)

		if run.size() >= 2:
			var fragment: Dictionary = feature.duplicate(true)
			fragment["points"] = run.duplicate()
			fragments.append(fragment)

		# Feature points are sampled densely, but also test the actual segments.
		# If a segment crosses the erase brush between samples, treat the feature as
		# hit. In that rare case, removing the source stroke is preferable to leaving
		# a thin bridge across the erased gap.
		if not feature_changed and _distance_to_polyline(point, points) <= erase_distance:
			feature_changed = true
			fragments.clear()

		if feature_changed:
			any_changed = true
			output.append_array(fragments)
		else:
			output.append(feature.duplicate(true))

	return {
		"features": output,
		"changed": any_changed,
	}

# =============================================================================
# BRUSHES
# =============================================================================

func _apply_brush(local_position: Vector3) -> void:
	if not is_instance_valid(_active_terrain):
		return

	# Paint can grow the canvas. Other sculpt/erase tools intentionally operate
	# only on terrain that already exists.
	var canvas_expanded := false
	if _tool_mode == ToolMode.PAINT:
		canvas_expanded = _ensure_canvas_for_paint(_active_terrain, local_position)

	var resolution: int = int(_active_terrain.get_meta(META_RESOLUTION))
	var world_size: float = float(_active_terrain.get_meta(META_WORLD_SIZE))
	var mask: PackedFloat32Array = _active_terrain.get_meta(META_MASK)
	var heights: PackedFloat32Array = _active_terrain.get_meta(META_HEIGHTS)
	var target_pos := Vector2(local_position.x, local_position.z)
	_accumulate_stroke_dirty_rect(target_pos, _brush_radius + 1.0)
	var bounds := _brush_vertex_bounds(_active_terrain, target_pos, _brush_radius)

	for z in range(bounds["min_z"], bounds["max_z"] + 1):
		for x in range(bounds["min_x"], bounds["max_x"] + 1):
			var point := _grid_to_local(x, z, resolution, world_size)
			var distance := Vector2(point.x, point.z).distance_to(target_pos)

			if distance > _brush_radius:
				continue

			var t := clamp(distance / maxf(_brush_radius, 0.001), 0.0, 1.0)
			var falloff := 1.0 - smoothstep(0.0, 1.0, t)
			var index := _grid_index(x, z, resolution)

			match _tool_mode:
				ToolMode.PAINT:
					mask[index] = clamp(mask[index] + falloff * 0.20 * _brush_strength, 0.0, 1.0)
				ToolMode.ERASE:
					mask[index] = clamp(mask[index] - falloff * 0.20 * _brush_strength, 0.0, 1.0)
				ToolMode.RAISE:
					heights[index] = clampf(heights[index] + falloff * 0.12 * _brush_strength, _terrain_height_min(_active_terrain), _terrain_height_max(_active_terrain))
				ToolMode.LOWER:
					heights[index] = clampf(heights[index] - falloff * 0.12 * _brush_strength, _terrain_height_min(_active_terrain), _terrain_height_max(_active_terrain))
				ToolMode.FLATTEN:
					var blend := clamp(falloff * 0.12 * _brush_strength, 0.0, 1.0)
					heights[index] = lerp(heights[index], _flatten_height, blend)

	_active_terrain.set_meta(META_MASK, mask)
	_active_terrain.set_meta(META_HEIGHTS, heights)

	var activated_cells := PackedInt32Array()
	if _tool_mode == ToolMode.PAINT:
		activated_cells = _sync_cell_active_near_brush(_active_terrain, target_pos, _brush_radius, true)
	elif _tool_mode == ToolMode.ERASE:
		# Erase is destructive only: it may deactivate existing cells, but must
		# never activate empty cells from the shared vertex mask around them.
		_sync_cell_active_near_brush(_active_terrain, target_pos, _brush_radius, false)

	if _tool_mode == ToolMode.PAINT and not activated_cells.is_empty():
		_assign_style_to_cell_indices(_active_terrain, activated_cells)

	if _tool_mode == ToolMode.SMOOTH:
		_apply_smooth_brush(local_position)

	if canvas_expanded:
		# Expansion recenters every old cell inside a larger grid. Chunk coordinates
		# therefore change globally, so all chunk meshes must be rebuilt once at the
		# expansion event. Subsequent samples return to dirty-chunk rebuilding.
		_rebuild_river_carve_cache(_active_terrain)
		_rebuild_all_terrain_chunks(_active_terrain)
	else:
		# Only the chunks intersecting this brush need new terrain geometry.
		_rebuild_terrain_chunks_for_brush(_active_terrain, target_pos, _brush_radius)


func _accumulate_stroke_dirty_rect(center: Vector2, radius: float) -> void:
	var r := maxf(radius, 0.0)
	var rect := Rect2(center - Vector2(r, r), Vector2(r * 2.0, r * 2.0))
	if not _stroke_has_dirty_rect:
		_stroke_dirty_rect = rect
		_stroke_has_dirty_rect = true
	else:
		_stroke_dirty_rect = _stroke_dirty_rect.merge(rect)


func _feature_bounds(feature: Dictionary, default_width: float) -> Rect2:
	var points: Array = feature.get("points", [])
	if points.is_empty():
		return Rect2()

	var first: Vector2 = points[0]
	var min_x := first.x
	var max_x := first.x
	var min_z := first.y
	var max_z := first.y
	for raw_point in points:
		var p: Vector2 = raw_point
		min_x = minf(min_x, p.x)
		max_x = maxf(max_x, p.x)
		min_z = minf(min_z, p.y)
		max_z = maxf(max_z, p.y)

	var margin := maxf(float(feature.get("width", default_width)) * 0.75, 0.5)
	return Rect2(
		Vector2(min_x - margin, min_z - margin),
		Vector2(max_x - min_x + margin * 2.0, max_z - min_z + margin * 2.0)
	)


func _features_intersect_rect(terrain: Node3D, rect: Rect2) -> bool:
	for road_variant in terrain.get_meta(META_ROADS, []):
		var road: Dictionary = road_variant
		if _feature_bounds(road, ROAD_WIDTH).intersects(rect):
			return true
	for river_variant in terrain.get_meta(META_RIVERS, []):
		var river: Dictionary = river_variant
		if _feature_bounds(river, RIVER_WIDTH).intersects(rect):
			return true
	return false


func _brush_vertex_bounds(terrain: Node3D, target_pos: Vector2, radius: float, padding_cells: int = 0) -> Dictionary:
	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	var world_size: float = float(terrain.get_meta(META_WORLD_SIZE, DEFAULT_WORLD_SIZE))
	var spacing: float = world_size / maxf(float(resolution - 1), 1.0)
	var center := _local_to_grid(target_pos, resolution, world_size)
	var grid_radius: float = radius / maxf(spacing, 0.0001) + float(padding_cells)

	return {
		"min_x": clampi(int(floor(center.x - grid_radius)), 0, resolution - 1),
		"max_x": clampi(int(ceil(center.x + grid_radius)), 0, resolution - 1),
		"min_z": clampi(int(floor(center.y - grid_radius)), 0, resolution - 1),
		"max_z": clampi(int(ceil(center.y + grid_radius)), 0, resolution - 1),
	}

func _apply_smooth_brush(local_position: Vector3) -> void:
	var resolution: int = int(_active_terrain.get_meta(META_RESOLUTION))
	var world_size: float = float(_active_terrain.get_meta(META_WORLD_SIZE))
	var source: PackedFloat32Array = _active_terrain.get_meta(META_HEIGHTS)
	var output := source.duplicate()
	var target_pos := Vector2(local_position.x, local_position.z)
	var bounds := _brush_vertex_bounds(_active_terrain, target_pos, _brush_radius, 1)

	var min_x: int = maxi(1, int(bounds["min_x"]))
	var max_x: int = mini(resolution - 2, int(bounds["max_x"]))
	var min_z: int = maxi(1, int(bounds["min_z"]))
	var max_z: int = mini(resolution - 2, int(bounds["max_z"]))

	for z in range(min_z, max_z + 1):
		for x in range(min_x, max_x + 1):
			var point := _grid_to_local(x, z, resolution, world_size)
			var distance := Vector2(point.x, point.z).distance_to(target_pos)

			if distance > _brush_radius:
				continue

			var average := 0.0
			var count := 0
			for dz in range(-1, 2):
				for dx in range(-1, 2):
					average += source[_grid_index(x + dx, z + dz, resolution)]
					count += 1
			average /= float(count)

			var t := clamp(distance / maxf(_brush_radius, 0.001), 0.0, 1.0)
			var falloff := 1.0 - smoothstep(0.0, 1.0, t)
			var blend := clamp(falloff * 0.20 * _brush_strength, 0.0, 1.0)
			var index := _grid_index(x, z, resolution)
			output[index] = lerp(source[index], average, blend)

	_active_terrain.set_meta(META_HEIGHTS, output)

# =============================================================================
# TERRAIN GENERATION
# =============================================================================

func _generate_terrain_mesh(terrain: Node3D, preview_feature: Dictionary = {}) -> void:
	if not is_instance_valid(terrain):
		return

	_ensure_terrain_material_data(terrain)
	_sync_material_cull_mode(terrain)
	_rebuild_river_carve_cache(terrain)
	_rebuild_all_terrain_chunks(terrain)

	var feature_collision_faces := _generate_feature_mesh(terrain)
	if not preview_feature.is_empty():
		_generate_feature_preview_mesh(terrain, preview_feature)
	if preview_feature.is_empty():
		_rebuild_terrain_collision_from_chunks(terrain, feature_collision_faces)


func _ensure_chunk_container(terrain: Node3D) -> Node3D:
	var container := terrain.get_node_or_null(GENERATED_CHUNKS_NAME) as Node3D
	if container:
		return container

	container = Node3D.new()
	container.name = GENERATED_CHUNKS_NAME
	terrain.add_child(container)
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root:
		container.owner = scene_root
	return container


func _chunk_name(chunk_x: int, chunk_z: int) -> String:
	return "Chunk_%d_%d" % [chunk_x, chunk_z]


func _get_or_create_chunk_mesh(terrain: Node3D, chunk_x: int, chunk_z: int) -> MeshInstance3D:
	var container := _ensure_chunk_container(terrain)
	var node_name := _chunk_name(chunk_x, chunk_z)
	var chunk := container.get_node_or_null(node_name) as MeshInstance3D
	if chunk:
		return chunk

	chunk = MeshInstance3D.new()
	chunk.name = node_name
	container.add_child(chunk)
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root:
		chunk.owner = scene_root
	return chunk


func _rebuild_all_terrain_chunks(terrain: Node3D) -> void:
	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	var cell_count: int = maxi(0, resolution - 1)
	var chunk_count_x: int = int(ceil(float(cell_count) / float(TERRAIN_CHUNK_CELLS)))
	var chunk_count_z: int = chunk_count_x
	var container := _ensure_chunk_container(terrain)
	var expected: Dictionary = {}

	for chunk_z in range(chunk_count_z):
		for chunk_x in range(chunk_count_x):
			expected[_chunk_name(chunk_x, chunk_z)] = true
			_rebuild_terrain_chunk(terrain, chunk_x, chunk_z)

	# Remove chunks left over after a smaller image generation / undo / resize.
	for child in container.get_children():
		if child is MeshInstance3D and not expected.has(child.name):
			container.remove_child(child)
			child.queue_free()


func _rebuild_terrain_chunks_for_brush(terrain: Node3D, target_pos: Vector2, brush_radius: float) -> void:
	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	if resolution < 2:
		return

	# One extra cell catches shared vertices and cliffs at chunk boundaries.
	var bounds := _brush_vertex_bounds(terrain, target_pos, brush_radius, 2)
	var min_cell_x: int = clampi(int(bounds["min_x"]) - 1, 0, resolution - 2)
	var max_cell_x: int = clampi(int(bounds["max_x"]), 0, resolution - 2)
	var min_cell_z: int = clampi(int(bounds["min_z"]) - 1, 0, resolution - 2)
	var max_cell_z: int = clampi(int(bounds["max_z"]), 0, resolution - 2)
	_rebuild_terrain_chunks_in_cell_rect(terrain, min_cell_x, min_cell_z, max_cell_x, max_cell_z)


func _rebuild_terrain_chunks_in_cell_rect(
	terrain: Node3D,
	min_cell_x: int,
	min_cell_z: int,
	max_cell_x: int,
	max_cell_z: int
) -> void:
	if max_cell_x < min_cell_x or max_cell_z < min_cell_z:
		return

	var min_chunk_x: int = int(floor(float(min_cell_x) / float(TERRAIN_CHUNK_CELLS)))
	var max_chunk_x: int = int(floor(float(max_cell_x) / float(TERRAIN_CHUNK_CELLS)))
	var min_chunk_z: int = int(floor(float(min_cell_z) / float(TERRAIN_CHUNK_CELLS)))
	var max_chunk_z: int = int(floor(float(max_cell_z) / float(TERRAIN_CHUNK_CELLS)))

	for chunk_z in range(min_chunk_z, max_chunk_z + 1):
		for chunk_x in range(min_chunk_x, max_chunk_x + 1):
			_rebuild_terrain_chunk(terrain, chunk_x, chunk_z)


func _rebuild_terrain_chunk(terrain: Node3D, chunk_x: int, chunk_z: int) -> void:
	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	var cell_count: int = resolution - 1
	var min_x: int = chunk_x * TERRAIN_CHUNK_CELLS
	var min_z: int = chunk_z * TERRAIN_CHUNK_CELLS
	if min_x >= cell_count or min_z >= cell_count:
		return

	var max_x: int = mini(min_x + TERRAIN_CHUNK_CELLS, cell_count)
	var max_z: int = mini(min_z + TERRAIN_CHUNK_CELLS, cell_count)
	var top_groups: Dictionary = {}
	var cliff_groups: Dictionary = {}

	for z in range(min_z, max_z):
		for x in range(min_x, max_x):
			if not _cell_active(terrain, x, z):
				continue

			var style_id: int = _cell_style_at(terrain, x, z)
			var top_group := _get_style_geometry_group(top_groups, style_id)
			var cliff_group := _get_style_geometry_group(cliff_groups, style_id)

			var p00 := _terrain_vertex(terrain, x, z)
			var p10 := _terrain_vertex(terrain, x + 1, z)
			var p01 := _terrain_vertex(terrain, x, z + 1)
			var p11 := _terrain_vertex(terrain, x + 1, z + 1)

			var top_offset: float = float(terrain.get_meta(META_TOP_Y_OFFSET, 0.0))
			p00.y += top_offset
			p10.y += top_offset
			p01.y += top_offset
			p11.y += top_offset

			_add_top_triangle(terrain, top_group["vertices"], top_group["normals"], p00, p10, p11)
			_add_top_triangle(terrain, top_group["vertices"], top_group["normals"], p00, p11, p01)
			_generate_cell_cliffs(terrain, x, z, p00, p10, p01, p11, cliff_group["vertices"], cliff_group["normals"])

	var array_mesh := ArrayMesh.new()

	var style_ids := top_groups.keys()
	style_ids.sort()
	for style_variant in style_ids:
		var style_id := int(style_variant)
		var group: Dictionary = top_groups[style_id]
		var tile_size := _tile_size_for_style(terrain, style_id, true)
		_add_surface(
			array_mesh,
			group["vertices"],
			group["normals"],
			_material_for_style(terrain, style_id, true),
			_generate_top_uvs(group["vertices"], tile_size)
		)

	style_ids = cliff_groups.keys()
	style_ids.sort()
	for style_variant in style_ids:
		var style_id := int(style_variant)
		var group: Dictionary = cliff_groups[style_id]
		var tile_size := _tile_size_for_style(terrain, style_id, false)
		_add_surface(
			array_mesh,
			group["vertices"],
			group["normals"],
			_material_for_style(terrain, style_id, false),
			_generate_cliff_uvs(group["vertices"], group["normals"], tile_size)
		)

	var chunk := _get_or_create_chunk_mesh(terrain, chunk_x, chunk_z)
	chunk.mesh = array_mesh


func _generate_feature_mesh(terrain: Node3D, preview_feature: Dictionary = {}) -> PackedVector3Array:
	var mesh_instance := terrain.get_node_or_null(GENERATED_MESH_NAME) as MeshInstance3D
	if not mesh_instance:
		return PackedVector3Array()

	var array_mesh := ArrayMesh.new()
	var feature_collision_faces := PackedVector3Array()

	var roads: Array = terrain.get_meta(META_ROADS, [])
	if not roads.is_empty():
		# Roads are generated from a unified occupancy footprint per connected
		# network. This removes overlapping ribbon surfaces, special-case junction
		# patches, sharp-corner self-overlap, loop seams, and coplanar z-fighting.
		for road_group_variant in _group_connected_roads(roads):
			var road_group: Array = road_group_variant
			if road_group.is_empty():
				continue
			var road_geometry := _build_road_surface_union(terrain, road_group)
			var representative: Dictionary = _migrate_feature_style(road_group[0], "road")
			_add_surface(
				array_mesh,
				road_geometry["vertices"],
				road_geometry["normals"],
				_road_material_for_feature(terrain, representative),
				road_geometry["uvs"]
			)
			var road_collision := false
			for road_variant in road_group:
				var road_check: Dictionary = _migrate_feature_style(road_variant, "road")
				if bool(road_check.get("collision", true)):
					road_collision = true
					break
			if road_collision:
				feature_collision_faces.append_array(PackedVector3Array(road_geometry["vertices"]))


	var rivers: Array = terrain.get_meta(META_RIVERS, [])
	if not rivers.is_empty():
		# Only rivers whose rasterized footprints touch are merged. Each disconnected
		# water body keeps the style of its first river, so separate rivers can have
		# different colors/textures while confluences remain one non-overlapping mesh.
		for river_group_variant in _group_connected_rivers(terrain, rivers):
			var river_group: Array = river_group_variant
			if river_group.is_empty():
				continue
			var river_geometry := _build_river_water_union(terrain, river_group)
			var representative: Dictionary = _migrate_feature_style(river_group[0], "river")
			_add_surface(array_mesh, river_geometry["vertices"], river_geometry["normals"], _river_material_for_feature(representative), river_geometry["uvs"])
			var water_collision := false
			for river_variant in river_group:
				var river: Dictionary = _migrate_feature_style(river_variant, "river")
				if bool(river.get("collision", false)):
					water_collision = true
					break
			if water_collision:
				feature_collision_faces.append_array(PackedVector3Array(river_geometry["collision_vertices"]))

	mesh_instance.mesh = array_mesh
	_feature_collision_cache[terrain.get_instance_id()] = feature_collision_faces
	return feature_collision_faces

func _get_or_create_feature_preview_mesh(terrain: Node3D) -> MeshInstance3D:
	var preview := terrain.get_node_or_null(GENERATED_PREVIEW_MESH_NAME) as MeshInstance3D
	if preview:
		return preview

	preview = MeshInstance3D.new()
	preview.name = GENERATED_PREVIEW_MESH_NAME
	terrain.add_child(preview)
	var scene_root := get_editor_interface().get_edited_scene_root()
	if scene_root:
		preview.owner = scene_root
	return preview


func _generate_feature_preview_mesh(terrain: Node3D, preview_feature: Dictionary) -> void:
	var preview_mesh := _get_or_create_feature_preview_mesh(terrain)
	if preview_feature.is_empty():
		preview_mesh.mesh = null
		return

	var array_mesh := ArrayMesh.new()
	var preview_type: String = str(preview_feature.get("type", "road"))
	var geometry := _build_feature_ribbon(terrain, preview_feature, preview_type)
	if preview_type == "road":
		_add_surface(array_mesh, geometry["vertices"], geometry["normals"], _road_material_for_feature(terrain, preview_feature), geometry["uvs"])
	else:
		_add_surface(array_mesh, geometry["vertices"], geometry["normals"], _river_material_for_feature(preview_feature), geometry["uvs"])
	preview_mesh.mesh = array_mesh


func _clear_feature_preview_mesh(terrain: Node3D) -> void:
	var preview := terrain.get_node_or_null(GENERATED_PREVIEW_MESH_NAME) as MeshInstance3D
	if preview:
		preview.mesh = null


func _get_cached_feature_collision_faces(terrain: Node3D) -> PackedVector3Array:
	var terrain_id := terrain.get_instance_id()
	if _feature_collision_cache.has(terrain_id):
		return _feature_collision_cache[terrain_id]
	return _generate_feature_mesh(terrain)




func _rebuild_terrain_collision_from_chunks(
	terrain: Node3D,
	feature_faces: PackedVector3Array = PackedVector3Array()
) -> void:
	var enabled: bool = bool(terrain.get_meta(META_COLLISION_ENABLED, false))
	var body := terrain.get_node_or_null(GENERATED_COLLISION_BODY_NAME) as StaticBody3D

	if not enabled:
		if body:
			var existing_shape := body.get_node_or_null(GENERATED_COLLISION_SHAPE_NAME) as CollisionShape3D
			if existing_shape:
				existing_shape.disabled = true
		return

	var scene_root := get_editor_interface().get_edited_scene_root()
	if not body:
		body = StaticBody3D.new()
		body.name = GENERATED_COLLISION_BODY_NAME
		terrain.add_child(body)
		if scene_root:
			body.owner = scene_root

	var collision_shape := body.get_node_or_null(GENERATED_COLLISION_SHAPE_NAME) as CollisionShape3D
	if not collision_shape:
		collision_shape = CollisionShape3D.new()
		collision_shape.name = GENERATED_COLLISION_SHAPE_NAME
		body.add_child(collision_shape)
		if scene_root:
			collision_shape.owner = scene_root

	var layer_number := clampi(int(terrain.get_meta(META_COLLISION_LAYER, 1)), 1, 32)
	body.collision_layer = 1 << (layer_number - 1)
	body.collision_mask = 0

	var faces := PackedVector3Array()
	var container := terrain.get_node_or_null(GENERATED_CHUNKS_NAME) as Node3D
	if container:
		for child in container.get_children():
			var chunk := child as MeshInstance3D
			if chunk != null and chunk.mesh != null:
				faces.append_array(chunk.mesh.get_faces())

	if not feature_faces.is_empty():
		faces.append_array(feature_faces)

	if faces.is_empty():
		collision_shape.shape = null
		collision_shape.disabled = true
		return

	var concave := ConcavePolygonShape3D.new()
	concave.backface_collision = true
	concave.set_faces(faces)
	collision_shape.shape = concave
	collision_shape.disabled = false

func _terrain_height_min(terrain: Node3D) -> float:
	return float(terrain.get_meta(META_HEIGHT_MIN, HEIGHT_MIN))

func _terrain_height_max(terrain: Node3D) -> float:
	return float(terrain.get_meta(META_HEIGHT_MAX, HEIGHT_MAX))


func _terrain_vertex(terrain: Node3D, x: int, z: int) -> Vector3:
	var resolution: int = terrain.get_meta(META_RESOLUTION)
	var world_size: float = terrain.get_meta(META_WORLD_SIZE)
	var base := _grid_to_local(x, z, resolution, world_size)
	base.y = _effective_height_at_grid(terrain, x, z)
	return base

func _effective_height_at_grid(terrain: Node3D, x: int, z: int) -> float:
	var resolution: int = int(terrain.get_meta(META_RESOLUTION))
	var heights: PackedFloat32Array = terrain.get_meta(META_HEIGHTS)
	var index := _grid_index(x, z, resolution)
	var base_height: float = heights[index]

	var terrain_id := terrain.get_instance_id()
	var carve: PackedFloat32Array = _river_carve_cache.get(terrain_id, PackedFloat32Array())
	if carve.size() != resolution * resolution:
		_rebuild_river_carve_cache(terrain)
		carve = _river_carve_cache.get(terrain_id, PackedFloat32Array())

	if index >= 0 and index < carve.size():
		return base_height - carve[index]
	return base_height


func _rebuild_river_carve_cache(terrain: Node3D) -> void:
	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	var world_size: float = float(terrain.get_meta(META_WORLD_SIZE, DEFAULT_WORLD_SIZE))
	var carve := PackedFloat32Array()
	carve.resize(resolution * resolution)
	carve.fill(0.0)

	if resolution < 2:
		_river_carve_cache[terrain.get_instance_id()] = carve
		return

	for river_variant in terrain.get_meta(META_RIVERS, []):
		var river: Dictionary = _migrate_feature_style(river_variant, "river")
		var raw_points: Array = river.get("points", [])
		if raw_points.size() < 2:
			continue

		var width: float = maxf(float(river.get("width", RIVER_WIDTH)), 0.01)
		var radius: float = width * 0.62
		var depth: float = maxf(float(river.get("depth", RIVER_DEPTH)), 0.0)
		if depth <= 0.0:
			continue

		for segment_index in range(raw_points.size() - 1):
			var a: Vector2 = raw_points[segment_index]
			var b: Vector2 = raw_points[segment_index + 1]
			var local_min := Vector2(minf(a.x, b.x) - radius, minf(a.y, b.y) - radius)
			var local_max := Vector2(maxf(a.x, b.x) + radius, maxf(a.y, b.y) + radius)
			var grid_min := _local_to_grid(local_min, resolution, world_size)
			var grid_max := _local_to_grid(local_max, resolution, world_size)

			var min_x := clampi(int(floor(minf(grid_min.x, grid_max.x))), 0, resolution - 1)
			var max_x := clampi(int(ceil(maxf(grid_min.x, grid_max.x))), 0, resolution - 1)
			var min_z := clampi(int(floor(minf(grid_min.y, grid_max.y))), 0, resolution - 1)
			var max_z := clampi(int(ceil(maxf(grid_min.y, grid_max.y))), 0, resolution - 1)

			for z in range(min_z, max_z + 1):
				for x in range(min_x, max_x + 1):
					var p3 := _grid_to_local(x, z, resolution, world_size)
					var point := Vector2(p3.x, p3.z)
					var distance := _distance_to_segment(point, a, b)
					if distance >= radius:
						continue
					var factor: float = 1.0 - clampf(distance / radius, 0.0, 1.0)
					factor = smoothstep(0.0, 1.0, factor)
					var index := _grid_index(x, z, resolution)
					carve[index] = maxf(carve[index], depth * factor)

	_river_carve_cache[terrain.get_instance_id()] = carve

func _generate_cell_cliffs(
	terrain: Node3D, x: int, z: int, p00: Vector3, p10: Vector3, p01: Vector3, p11: Vector3,
	vertices: Array, normals: Array
) -> void:
	if not _cell_active(terrain, x - 1, z): _add_cliff_quad(terrain, p00, p01, Vector3.LEFT, vertices, normals)
	if not _cell_active(terrain, x + 1, z): _add_cliff_quad(terrain, p11, p10, Vector3.RIGHT, vertices, normals)
	# Grid z- is local -Z (Godot FORWARD); grid z+ is local +Z (BACK).
	if not _cell_active(terrain, x, z - 1): _add_cliff_quad(terrain, p10, p00, Vector3.FORWARD, vertices, normals)
	if not _cell_active(terrain, x, z + 1): _add_cliff_quad(terrain, p01, p11, Vector3.BACK, vertices, normals)

func _add_cliff_quad(terrain: Node3D, top_a: Vector3, top_b: Vector3, outward: Vector3, vertices: Array, normals: Array) -> void:
	var base_y: float = terrain.get_meta(META_BASE_Y, DEFAULT_BASE_Y)
	var cliff_offset: float = terrain.get_meta(META_CLIFF_Y_OFFSET, 0.0)
	top_a.y += cliff_offset
	top_b.y += cliff_offset
	var bottom_a := Vector3(top_a.x, base_y, top_a.z)
	var bottom_b := Vector3(top_b.x, base_y, top_b.z)

	# A cliff is conceptually vertical. Both triangles share one horizontal outward
	# normal. _add_oriented_triangle() also enforces Godot's clockwise front-face
	# convention, so culling and lighting agree instead of fighting each other.
	var wall_normal := outward.normalized()
	_add_oriented_triangle(vertices, normals, top_a, top_b, bottom_b, wall_normal)
	_add_oriented_triangle(vertices, normals, top_a, bottom_b, bottom_a, wall_normal)

func _cell_active(terrain: Node3D, x: int, z: int) -> bool:
	var resolution: int = terrain.get_meta(META_RESOLUTION)
	if x < 0 or z < 0 or x >= resolution - 1 or z >= resolution - 1:
		return false
	if terrain.has_meta(META_CELL_ACTIVE):
		var cells: PackedByteArray = terrain.get_meta(META_CELL_ACTIVE)
		var index: int = _cell_style_index(x, z, resolution)
		if index >= 0 and index < cells.size():
			return cells[index] != 0
	var mask: PackedFloat32Array = terrain.get_meta(META_MASK)
	return _cell_active_for_mask(mask, x, z, resolution)

# =============================================================================
# RIVER WATER BODY
# =============================================================================

func _river_paths_touch(terrain: Node3D, river_a_variant: Variant, river_b_variant: Variant) -> bool:
	var river_a: Dictionary = _migrate_feature_style(river_a_variant, "river")
	var river_b: Dictionary = _migrate_feature_style(river_b_variant, "river")
	var points_a: Array = river_a.get("points", [])
	var points_b: Array = river_b.get("points", [])
	if points_a.size() < 2 or points_b.size() < 2:
		return false

	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	var world_size: float = float(terrain.get_meta(META_WORLD_SIZE, DEFAULT_WORLD_SIZE))
	var spacing: float = world_size / maxf(float(resolution - 1), 1.0)
	# Match the rasterized river footprint rather than only the exact centerline.
	var touch_distance: float = (
		float(river_a.get("width", RIVER_WIDTH)) * 0.5
		+ float(river_b.get("width", RIVER_WIDTH)) * 0.5
		+ spacing * 1.40
	)

	for ai in range(points_a.size() - 1):
		var a0: Vector2 = points_a[ai]
		var a1: Vector2 = points_a[ai + 1]
		for bi in range(points_b.size() - 1):
			var b0: Vector2 = points_b[bi]
			var b1: Vector2 = points_b[bi + 1]
			if _segment_intersection_2d(a0, a1, b0, b1) != null:
				return true
			var distance := minf(
				minf(_distance_to_segment(a0, b0, b1), _distance_to_segment(a1, b0, b1)),
				minf(_distance_to_segment(b0, a0, a1), _distance_to_segment(b1, a0, a1))
			)
			if distance <= touch_distance:
				return true
	return false


func _group_connected_rivers(terrain: Node3D, rivers: Array) -> Array:
	var groups: Array = []
	var visited: Dictionary = {}
	for start_index in range(rivers.size()):
		if visited.has(start_index):
			continue
		var group: Array = []
		var queue: Array[int] = [start_index]
		visited[start_index] = true
		while not queue.is_empty():
			var current_index: int = queue.pop_front()
			group.append(rivers[current_index])
			for candidate_index in range(rivers.size()):
				if visited.has(candidate_index):
					continue
				if _river_paths_touch(terrain, rivers[current_index], rivers[candidate_index]):
					visited[candidate_index] = true
					queue.append(candidate_index)
		groups.append(group)
	return groups


func _build_river_water_union(terrain: Node3D, rivers: Array) -> Dictionary:
	var vertices: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var uvs: Array[Vector2] = []
	var collision_vertices: Array[Vector3] = []
	if rivers.is_empty():
		return {"vertices": vertices, "normals": normals, "uvs": uvs, "collision_vertices": collision_vertices}

	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	var world_size: float = float(terrain.get_meta(META_WORLD_SIZE, DEFAULT_WORLD_SIZE))
	if resolution < 2:
		return {"vertices": vertices, "normals": normals, "uvs": uvs, "collision_vertices": collision_vertices}

	var spacing := world_size / float(resolution - 1)
	var water_cells: Dictionary = {}
	var representative: Dictionary = _migrate_feature_style(rivers[0], "river")
	var surface_drop: float = float(representative.get("surface_drop", 0.15))
	var feature_offset: float = float(terrain.get_meta(META_FEATURE_Y_OFFSET, 0.0))
	var tile_size: float = maxf(float(representative.get("tile_size", 6.0)), 0.001)

	# Rasterize every river into one shared cell mask. A cell claimed by several
	# rivers is still emitted exactly once, eliminating the dark overlapping top
	# faces at confluences and crossings.
	for river_variant in rivers:
		var river: Dictionary = _migrate_feature_style(river_variant, "river")
		var raw_points: Array = river.get("points", [])
		if raw_points.size() < 2:
			continue
		var points: Array[Vector2] = []
		for point_variant in raw_points:
			var point: Vector2 = point_variant
			if points.is_empty() or points[-1].distance_squared_to(point) > 0.000001:
				points.append(point)
		if points.size() < 2:
			continue

		var width: float = maxf(float(river.get("width", RIVER_WIDTH)), 0.01)
		var inclusion_radius: float = width * 0.5 + spacing * 0.70
		var min_px: float = points[0].x
		var max_px: float = points[0].x
		var min_pz: float = points[0].y
		var max_pz: float = points[0].y
		for p in points:
			min_px = minf(min_px, p.x)
			max_px = maxf(max_px, p.x)
			min_pz = minf(min_pz, p.y)
			max_pz = maxf(max_pz, p.y)

		var min_grid := _local_to_grid(Vector2(min_px - inclusion_radius, min_pz - inclusion_radius), resolution, world_size)
		var max_grid := _local_to_grid(Vector2(max_px + inclusion_radius, max_pz + inclusion_radius), resolution, world_size)
		var min_cell_x := clampi(int(floor(minf(min_grid.x, max_grid.x))) - 1, 0, resolution - 2)
		var max_cell_x := clampi(int(ceil(maxf(min_grid.x, max_grid.x))) + 1, 0, resolution - 2)
		var min_cell_z := clampi(int(floor(minf(min_grid.y, max_grid.y))) - 1, 0, resolution - 2)
		var max_cell_z := clampi(int(ceil(maxf(min_grid.y, max_grid.y))) + 1, 0, resolution - 2)

		for z in range(min_cell_z, max_cell_z + 1):
			for x in range(min_cell_x, max_cell_x + 1):
				if not _cell_active(terrain, x, z):
					continue
				var p00 := _grid_to_local(x, z, resolution, world_size)
				var p11 := _grid_to_local(x + 1, z + 1, resolution, world_size)
				var center := Vector2((p00.x + p11.x) * 0.5, (p00.z + p11.z) * 0.5)
				if _distance_to_polyline(center, points) <= inclusion_radius:
					water_cells[Vector2i(x, z)] = true

	for key_variant in water_cells.keys():
		var cell: Vector2i = key_variant
		var x: int = cell.x
		var z: int = cell.y
		var a2 := _grid_to_local(x, z, resolution, world_size)
		var b2 := _grid_to_local(x + 1, z, resolution, world_size)
		var c2 := _grid_to_local(x + 1, z + 1, resolution, world_size)
		var d2 := _grid_to_local(x, z + 1, resolution, world_size)
		var a := Vector3(a2.x, _sample_uncarved_height(terrain, Vector2(a2.x, a2.z)) - surface_drop + feature_offset, a2.z)
		var b := Vector3(b2.x, _sample_uncarved_height(terrain, Vector2(b2.x, b2.z)) - surface_drop + feature_offset, b2.z)
		var c := Vector3(c2.x, _sample_uncarved_height(terrain, Vector2(c2.x, c2.z)) - surface_drop + feature_offset, c2.z)
		var d := Vector3(d2.x, _sample_uncarved_height(terrain, Vector2(d2.x, d2.z)) - surface_drop + feature_offset, d2.z)
		var uv_a := Vector2(a.x / tile_size, a.z / tile_size)
		var uv_b := Vector2(b.x / tile_size, b.z / tile_size)
		var uv_c := Vector2(c.x / tile_size, c.z / tile_size)
		var uv_d := Vector2(d.x / tile_size, d.z / tile_size)
		_add_upward_triangle_uv(vertices, normals, uvs, a, b, c, uv_a, uv_b, uv_c)
		_add_upward_triangle_uv(vertices, normals, uvs, a, c, d, uv_a, uv_c, uv_d)
		_add_upward_triangle(collision_vertices, [], a, b, c)
		_add_upward_triangle(collision_vertices, [], a, c, d)

	# Only the outer boundary of the complete union receives skirts. Internal
	# river/river borders disappear, so intersections read as one continuous body.
	for key_variant in water_cells.keys():
		var cell: Vector2i = key_variant
		_add_river_boundary_skirt(terrain, water_cells, cell.x, cell.y, Vector2i(-1, 0), representative, vertices, normals, uvs, tile_size)
		_add_river_boundary_skirt(terrain, water_cells, cell.x, cell.y, Vector2i(1, 0), representative, vertices, normals, uvs, tile_size)
		_add_river_boundary_skirt(terrain, water_cells, cell.x, cell.y, Vector2i(0, -1), representative, vertices, normals, uvs, tile_size)
		_add_river_boundary_skirt(terrain, water_cells, cell.x, cell.y, Vector2i(0, 1), representative, vertices, normals, uvs, tile_size)

	return {"vertices": vertices, "normals": normals, "uvs": uvs, "collision_vertices": collision_vertices}


func _build_river_water_body(terrain: Node3D, feature: Dictionary) -> Dictionary:
	var vertices: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var uvs: Array[Vector2] = []
	var collision_vertices: Array[Vector3] = []
	var raw_points: Array = feature.get("points", [])
	if raw_points.size() < 2:
		return {"vertices": vertices, "normals": normals, "uvs": uvs, "collision_vertices": collision_vertices}

	var points: Array[Vector2] = []
	for point_variant in raw_points:
		var point: Vector2 = point_variant
		if points.is_empty() or points[-1].distance_squared_to(point) > 0.000001:
			points.append(point)
	if points.size() < 2:
		return {"vertices": vertices, "normals": normals, "uvs": uvs, "collision_vertices": collision_vertices}

	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	var world_size: float = float(terrain.get_meta(META_WORLD_SIZE, DEFAULT_WORLD_SIZE))
	if resolution < 2:
		return {"vertices": vertices, "normals": normals, "uvs": uvs, "collision_vertices": collision_vertices}

	var spacing: float = world_size / float(resolution - 1)
	var width: float = maxf(float(feature.get("width", RIVER_WIDTH)), 0.01)
	var radius: float = width * 0.5
	var surface_drop: float = float(feature.get("surface_drop", 0.15))
	var feature_offset: float = float(terrain.get_meta(META_FEATURE_Y_OFFSET, 0.0))
	var tile_size: float = maxf(float(feature.get("tile_size", 6.0)), 0.001)

	# A dictionary acts as the union mask. This is the key difference from the old
	# segment ribbon: loops can cross themselves but a grid cell is emitted once.
	var water_cells: Dictionary = {}
	var inclusion_radius: float = radius + spacing * 0.70

	var min_px: float = points[0].x
	var max_px: float = points[0].x
	var min_pz: float = points[0].y
	var max_pz: float = points[0].y
	for p in points:
		min_px = minf(min_px, p.x)
		max_px = maxf(max_px, p.x)
		min_pz = minf(min_pz, p.y)
		max_pz = maxf(max_pz, p.y)

	var min_grid := _local_to_grid(Vector2(min_px - inclusion_radius, min_pz - inclusion_radius), resolution, world_size)
	var max_grid := _local_to_grid(Vector2(max_px + inclusion_radius, max_pz + inclusion_radius), resolution, world_size)
	var min_cell_x := clampi(int(floor(minf(min_grid.x, max_grid.x))) - 1, 0, resolution - 2)
	var max_cell_x := clampi(int(ceil(maxf(min_grid.x, max_grid.x))) + 1, 0, resolution - 2)
	var min_cell_z := clampi(int(floor(minf(min_grid.y, max_grid.y))) - 1, 0, resolution - 2)
	var max_cell_z := clampi(int(ceil(maxf(min_grid.y, max_grid.y))) + 1, 0, resolution - 2)

	for z in range(min_cell_z, max_cell_z + 1):
		for x in range(min_cell_x, max_cell_x + 1):
			if not _cell_active(terrain, x, z):
				continue
			var p00 := _grid_to_local(x, z, resolution, world_size)
			var p11 := _grid_to_local(x + 1, z + 1, resolution, world_size)
			var center := Vector2((p00.x + p11.x) * 0.5, (p00.z + p11.z) * 0.5)
			if _distance_to_polyline(center, points) <= inclusion_radius:
				water_cells[Vector2i(x, z)] = true

	# Emit exactly one top quad per selected cell. UVs are world-planar even though
	# the water shader also uses world position, making manual material replacement sane.
	for key_variant in water_cells.keys():
		var cell: Vector2i = key_variant
		var x: int = cell.x
		var z: int = cell.y
		var a2 := _grid_to_local(x, z, resolution, world_size)
		var b2 := _grid_to_local(x + 1, z, resolution, world_size)
		var c2 := _grid_to_local(x + 1, z + 1, resolution, world_size)
		var d2 := _grid_to_local(x, z + 1, resolution, world_size)

		var a := Vector3(a2.x, _sample_uncarved_height(terrain, Vector2(a2.x, a2.z)) - surface_drop + feature_offset, a2.z)
		var b := Vector3(b2.x, _sample_uncarved_height(terrain, Vector2(b2.x, b2.z)) - surface_drop + feature_offset, b2.z)
		var c := Vector3(c2.x, _sample_uncarved_height(terrain, Vector2(c2.x, c2.z)) - surface_drop + feature_offset, c2.z)
		var d := Vector3(d2.x, _sample_uncarved_height(terrain, Vector2(d2.x, d2.z)) - surface_drop + feature_offset, d2.z)

		var uv_a := Vector2(a.x / tile_size, a.z / tile_size)
		var uv_b := Vector2(b.x / tile_size, b.z / tile_size)
		var uv_c := Vector2(c.x / tile_size, c.z / tile_size)
		var uv_d := Vector2(d.x / tile_size, d.z / tile_size)
		_add_upward_triangle_uv(vertices, normals, uvs, a, b, c, uv_a, uv_b, uv_c)
		_add_upward_triangle_uv(vertices, normals, uvs, a, c, d, uv_a, uv_c, uv_d)
		_add_upward_triangle(collision_vertices, [], a, b, c)
		_add_upward_triangle(collision_vertices, [], a, c, d)

	# Close every exposed boundary edge down to the carved terrain. These skirts
	# make the water read as a body at both long banks and, importantly, the two
	# stroke tips instead of exposing a paper-thin plane there.
	for key_variant in water_cells.keys():
		var cell: Vector2i = key_variant
		var x: int = cell.x
		var z: int = cell.y
		_add_river_boundary_skirt(terrain, water_cells, x, z, Vector2i(-1, 0), feature, vertices, normals, uvs, tile_size)
		_add_river_boundary_skirt(terrain, water_cells, x, z, Vector2i(1, 0), feature, vertices, normals, uvs, tile_size)
		_add_river_boundary_skirt(terrain, water_cells, x, z, Vector2i(0, -1), feature, vertices, normals, uvs, tile_size)
		_add_river_boundary_skirt(terrain, water_cells, x, z, Vector2i(0, 1), feature, vertices, normals, uvs, tile_size)

	return {"vertices": vertices, "normals": normals, "uvs": uvs, "collision_vertices": collision_vertices}

func _add_river_boundary_skirt(terrain: Node3D, water_cells: Dictionary, x: int, z: int, direction: Vector2i, feature: Dictionary, vertices: Array, normals: Array, uvs: Array, tile_size: float) -> void:
	if water_cells.has(Vector2i(x, z) + direction):
		return
	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	var world_size: float = float(terrain.get_meta(META_WORLD_SIZE, DEFAULT_WORLD_SIZE))
	var surface_drop: float = float(feature.get("surface_drop", 0.15))
	var feature_offset: float = float(terrain.get_meta(META_FEATURE_Y_OFFSET, 0.0))

	var va: Vector3
	var vb: Vector3
	var outward: Vector3
	if direction == Vector2i(-1, 0):
		va = _grid_to_local(x, z + 1, resolution, world_size)
		vb = _grid_to_local(x, z, resolution, world_size)
		outward = Vector3.LEFT
	elif direction == Vector2i(1, 0):
		va = _grid_to_local(x + 1, z, resolution, world_size)
		vb = _grid_to_local(x + 1, z + 1, resolution, world_size)
		outward = Vector3.RIGHT
	elif direction == Vector2i(0, -1):
		va = _grid_to_local(x, z, resolution, world_size)
		vb = _grid_to_local(x + 1, z, resolution, world_size)
		outward = Vector3.FORWARD
	else:
		va = _grid_to_local(x + 1, z + 1, resolution, world_size)
		vb = _grid_to_local(x, z + 1, resolution, world_size)
		outward = Vector3.BACK

	var a2 := Vector2(va.x, va.z)
	var b2 := Vector2(vb.x, vb.z)
	var top_a := Vector3(va.x, _sample_uncarved_height(terrain, a2) - surface_drop + feature_offset, va.z)
	var top_b := Vector3(vb.x, _sample_uncarved_height(terrain, b2) - surface_drop + feature_offset, vb.z)
	var bed_a := Vector3(va.x, _sample_effective_height(terrain, a2) + 0.01, va.z)
	var bed_b := Vector3(vb.x, _sample_effective_height(terrain, b2) + 0.01, vb.z)
	# Never let the skirt invert on shallow bank corners.
	bed_a.y = minf(bed_a.y, top_a.y - 0.015)
	bed_b.y = minf(bed_b.y, top_b.y - 0.015)

	var u0: float = 0.0
	var u1: float = top_a.distance_to(top_b) / maxf(tile_size, 0.001)
	var v0: float = 0.0
	var v1a: float = absf(top_a.y - bed_a.y) / maxf(tile_size, 0.001)
	var v1b: float = absf(top_b.y - bed_b.y) / maxf(tile_size, 0.001)
	_add_oriented_triangle_uv(vertices, normals, uvs, top_a, bed_b, top_b, outward, Vector2(u0, v0), Vector2(u1, v1b), Vector2(u1, v0))
	_add_oriented_triangle_uv(vertices, normals, uvs, top_a, bed_a, bed_b, outward, Vector2(u0, v0), Vector2(u0, v1a), Vector2(u1, v1b))

func _add_oriented_triangle_uv(vertices: Array, normals: Array, uvs: Array, a: Vector3, b: Vector3, c: Vector3, desired_normal: Vector3, uv_a: Vector2, uv_b: Vector2, uv_c: Vector2) -> void:
	var cross := (b - a).cross(c - a)
	if cross.length_squared() <= 0.0000001:
		return
	var n := desired_normal.normalized()
	if cross.dot(n) > 0.0:
		var temp_vertex := b
		b = c
		c = temp_vertex
		var temp_uv := uv_b
		uv_b = uv_c
		uv_c = temp_uv
	vertices.append_array([a, b, c])
	normals.append_array([n, n, n])
	uvs.append_array([uv_a, uv_b, uv_c])


# =============================================================================
# ROAD UNION SURFACE
# =============================================================================

func _segment_segment_distance_2d(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> float:
	var hit = _segment_intersection_2d(a0, a1, b0, b1)
	if hit != null:
		return 0.0
	return minf(
		minf(_distance_to_segment(a0, b0, b1), _distance_to_segment(a1, b0, b1)),
		minf(_distance_to_segment(b0, a0, a1), _distance_to_segment(b1, a0, a1))
	)


func _road_footprints_touch(road_a_variant: Variant, road_b_variant: Variant) -> bool:
	var road_a: Dictionary = _migrate_feature_style(road_a_variant, "road")
	var road_b: Dictionary = _migrate_feature_style(road_b_variant, "road")
	var points_a: Array = road_a.get("points", [])
	var points_b: Array = road_b.get("points", [])
	if points_a.size() < 2 or points_b.size() < 2:
		return false

	var touch_distance := (
		maxf(float(road_a.get("width", ROAD_WIDTH)), 0.01)
		+ maxf(float(road_b.get("width", ROAD_WIDTH)), 0.01)
	) * 0.5 + ROAD_UNION_CELL_SIZE * 0.75

	for ai in range(points_a.size() - 1):
		var a0: Vector2 = points_a[ai]
		var a1: Vector2 = points_a[ai + 1]
		for bi in range(points_b.size() - 1):
			var b0: Vector2 = points_b[bi]
			var b1: Vector2 = points_b[bi + 1]
			if _segment_segment_distance_2d(a0, a1, b0, b1) <= touch_distance:
				return true
	return false


func _group_connected_roads(roads: Array) -> Array:
	var groups: Array = []
	var visited: Dictionary = {}

	for start_index in range(roads.size()):
		if visited.has(start_index):
			continue

		var group: Array = []
		var queue: Array[int] = [start_index]
		visited[start_index] = true

		while not queue.is_empty():
			var index: int = queue.pop_front()
			group.append(roads[index])

			for candidate in range(roads.size()):
				if visited.has(candidate):
					continue
				if _road_footprints_touch(roads[index], roads[candidate]):
					visited[candidate] = true
					queue.append(candidate)

		groups.append(group)

	return groups


func _road_union_cell_size(terrain: Node3D) -> float:
	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	var world_size: float = float(terrain.get_meta(META_WORLD_SIZE, DEFAULT_WORLD_SIZE))
	var terrain_spacing := world_size / maxf(float(resolution - 1), 1.0)
	# Keep the derived road mesh at least as dense as the old conforming ribbon
	# and usually about twice as dense as a 1-unit terrain grid.
	return maxf(0.20, minf(ROAD_UNION_CELL_SIZE, terrain_spacing * 0.5))


func _rasterize_road_group(terrain: Node3D, road_group: Array, cell_size: float) -> Dictionary:
	var occupied: Dictionary = {}
	var half_diagonal := cell_size * 0.70710678
	var edge_padding := cell_size * ROAD_UNION_EDGE_PADDING + half_diagonal * 0.35

	for road_variant in road_group:
		var road: Dictionary = _migrate_feature_style(road_variant, "road")
		var raw_points: Array = road.get("points", [])
		if raw_points.size() < 2:
			continue

		var points: Array[Vector2] = []
		for point_variant in raw_points:
			var point: Vector2 = point_variant
			if points.is_empty() or points[-1].distance_squared_to(point) > 0.000001:
				points.append(point)
		if points.size() < 2:
			continue

		var radius := maxf(float(road.get("width", ROAD_WIDTH)) * 0.5, 0.01)
		var claim_radius := radius + edge_padding

		for segment_index in range(points.size() - 1):
			var a := points[segment_index]
			var b := points[segment_index + 1]
			var min_x := mini(
				int(floor((minf(a.x, b.x) - claim_radius) / cell_size)),
				int(floor((maxf(a.x, b.x) + claim_radius) / cell_size))
			)
			var max_x := maxi(
				int(floor((minf(a.x, b.x) - claim_radius) / cell_size)),
				int(floor((maxf(a.x, b.x) + claim_radius) / cell_size))
			)
			var min_z := mini(
				int(floor((minf(a.y, b.y) - claim_radius) / cell_size)),
				int(floor((maxf(a.y, b.y) + claim_radius) / cell_size))
			)
			var max_z := maxi(
				int(floor((minf(a.y, b.y) - claim_radius) / cell_size)),
				int(floor((maxf(a.y, b.y) + claim_radius) / cell_size))
			)

			for cell_z in range(min_z, max_z + 1):
				for cell_x in range(min_x, max_x + 1):
					var center := Vector2(
						(float(cell_x) + 0.5) * cell_size,
						(float(cell_z) + 0.5) * cell_size
					)
					if _distance_to_segment(center, a, b) <= claim_radius:
						occupied[Vector2i(cell_x, cell_z)] = true

	return occupied


func _build_road_surface_union(terrain: Node3D, road_group: Array) -> Dictionary:
	var vertices: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var uvs: Array[Vector2] = []
	if road_group.is_empty():
		return {"vertices": vertices, "normals": normals, "uvs": uvs}

	var representative: Dictionary = _migrate_feature_style(road_group[0], "road")
	var cell_size := _road_union_cell_size(terrain)
	var occupied := _rasterize_road_group(terrain, road_group, cell_size)
	var tile_size := maxf(float(representative.get("tile_size", 4.0)), 0.001)
	var feature_offset: float = float(terrain.get_meta(META_FEATURE_Y_OFFSET, 0.0))
	var y_offset: float = float(representative.get("y_offset", 0.035)) + feature_offset

	var keys: Array = occupied.keys()
	keys.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
		return a.y < b.y or (a.y == b.y and a.x < b.x)
	)

	for key_variant in keys:
		var key: Vector2i = key_variant
		var x0 := float(key.x) * cell_size
		var z0 := float(key.y) * cell_size
		var x1 := x0 + cell_size
		var z1 := z0 + cell_size

		var p00_2 := Vector2(x0, z0)
		var p10_2 := Vector2(x1, z0)
		var p01_2 := Vector2(x0, z1)
		var p11_2 := Vector2(x1, z1)

		var p00 := Vector3(x0, _sample_effective_height(terrain, p00_2) + y_offset, z0)
		var p10 := Vector3(x1, _sample_effective_height(terrain, p10_2) + y_offset, z0)
		var p01 := Vector3(x0, _sample_effective_height(terrain, p01_2) + y_offset, z1)
		var p11 := Vector3(x1, _sample_effective_height(terrain, p11_2) + y_offset, z1)

		# World-planar UVs deliberately replace longitudinal ribbon UVs. A unified
		# crossroads has no single "forward" direction, while planar projection
		# stays continuous across intersections, loops, overlaps, and sharp turns.
		var uv00 := p00_2 / tile_size
		var uv10 := p10_2 / tile_size
		var uv01 := p01_2 / tile_size
		var uv11 := p11_2 / tile_size

		_add_upward_triangle_uv(vertices, normals, uvs, p00, p11, p10, uv00, uv11, uv10)
		_add_upward_triangle_uv(vertices, normals, uvs, p00, p01, p11, uv00, uv01, uv11)

	return {
		"vertices": vertices,
		"normals": normals,
		"uvs": uvs,
	}


# =============================================================================
# ROAD / RIVER STRIPS
# =============================================================================

func _resample_road_points_conforming(points: Array[Vector2], spacing: float = ROAD_SAMPLE_SPACING) -> Array[Vector2]:
	if points.size() < 2:
		return points.duplicate()
	var result: Array[Vector2] = []
	result.append(points[0])
	for i in range(points.size() - 1):
		var a: Vector2 = points[i]
		var b: Vector2 = points[i + 1]
		var length := a.distance_to(b)
		var steps := maxi(1, int(ceil(length / maxf(spacing, 0.05))))
		for step in range(1, steps + 1):
			result.append(a.lerp(b, float(step) / float(steps)))
	return result


func _segment_intersection_2d(a0: Vector2, a1: Vector2, b0: Vector2, b1: Vector2) -> Variant:
	var r := a1 - a0
	var s := b1 - b0
	var denominator := r.cross(s)
	if absf(denominator) <= 0.000001:
		return null
	var offset := b0 - a0
	var t := offset.cross(s) / denominator
	var u := offset.cross(r) / denominator
	if t < 0.0 or t > 1.0 or u < 0.0 or u > 1.0:
		return null
	return a0 + r * t


func _collect_road_junctions(roads: Array) -> Array:
	var junctions: Array = []
	for i in range(roads.size()):
		var road_a: Dictionary = _migrate_feature_style(roads[i], "road")
		var points_a: Array = road_a.get("points", [])
		for j in range(i + 1, roads.size()):
			var road_b: Dictionary = _migrate_feature_style(roads[j], "road")
			var points_b: Array = road_b.get("points", [])
			for ai in range(points_a.size() - 1):
				for bi in range(points_b.size() - 1):
					var hit = _segment_intersection_2d(points_a[ai], points_a[ai + 1], points_b[bi], points_b[bi + 1])
					if hit == null:
						continue
					var hit_point: Vector2 = hit
					var radius := maxf(float(road_a.get("width", ROAD_WIDTH)), float(road_b.get("width", ROAD_WIDTH))) * ROAD_JUNCTION_RADIUS_SCALE
					var duplicate := false
					for existing_variant in junctions:
						var existing: Dictionary = existing_variant
						if Vector2(existing["position"]).distance_to(hit_point) < radius * 0.25:
							duplicate = true
							break
					if not duplicate:
						var dir_a: Vector2 = (Vector2(points_a[ai + 1]) - Vector2(points_a[ai])).normalized()
						var dir_b: Vector2 = (Vector2(points_b[bi + 1]) - Vector2(points_b[bi])).normalized()
						junctions.append({
							"position": hit_point,
							"radius": radius,
							"road": road_a,
							"road_a_index": i,
							"road_b_index": j,
							"direction_a": dir_a,
							"direction_b": dir_b,
							"width_a": float(road_a.get("width", ROAD_WIDTH)),
							"width_b": float(road_b.get("width", ROAD_WIDTH)),
						})
	return junctions


func _build_road_junction_patch(terrain: Node3D, junction: Dictionary) -> Dictionary:
	var vertices: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var uvs: Array[Vector2] = []
	var position: Vector2 = junction["position"]
	var radius: float = float(junction["radius"])
	var road: Dictionary = junction["road"]
	var y_offset: float = float(road.get("y_offset", 0.035)) + float(terrain.get_meta(META_FEATURE_Y_OFFSET, 0.0)) + 0.001
	var dir_a: Vector2 = Vector2(junction.get("direction_a", Vector2.RIGHT)).normalized()
	var dir_b: Vector2 = Vector2(junction.get("direction_b", Vector2.UP)).normalized()
	var half_a: float = maxf(float(junction.get("width_a", ROAD_WIDTH)) * 0.5, 0.01)
	var half_b: float = maxf(float(junction.get("width_b", ROAD_WIDTH)) * 0.5, 0.01)
	var normal_a := Vector2(-dir_a.y, dir_a.x)
	var normal_b := Vector2(-dir_b.y, dir_b.x)

	# Build the footprint from the actual incoming road rectangles instead of a
	# circular cap. The convex hull gives a compact crossroads shape whose edges
	# meet the clipped ribbons, so intersections no longer look like round islands.
	var footprint := PackedVector2Array()
	for sign_value in [-1.0, 1.0]:
		var end_a: Vector2 = position + dir_a * radius * sign_value
		footprint.append(end_a + normal_a * half_a)
		footprint.append(end_a - normal_a * half_a)
		var end_b: Vector2 = position + dir_b * radius * sign_value
		footprint.append(end_b + normal_b * half_b)
		footprint.append(end_b - normal_b * half_b)

	var hull: PackedVector2Array = Geometry2D.convex_hull(footprint)
	if hull.size() < 3:
		return {"vertices": vertices, "normals": normals, "uvs": uvs}

	var center_2d := Vector2.ZERO
	for p in hull:
		center_2d += p
	center_2d /= float(hull.size())
	var center := Vector3(center_2d.x, _sample_effective_height(terrain, center_2d) + y_offset, center_2d.y)
	var tile_size: float = maxf(float(road.get("tile_size", 4.0)), 0.001)

	for i in range(hull.size()):
		var p2_a: Vector2 = hull[i]
		var p2_b: Vector2 = hull[(i + 1) % hull.size()]
		var a := Vector3(p2_a.x, _sample_effective_height(terrain, p2_a) + y_offset, p2_a.y)
		var b := Vector3(p2_b.x, _sample_effective_height(terrain, p2_b) + y_offset, p2_b.y)
		_add_upward_triangle_uv(
			vertices, normals, uvs,
			center, b, a,
			center_2d / tile_size,
			p2_b / tile_size,
			p2_a / tile_size
		)
	return {"vertices": vertices, "normals": normals, "uvs": uvs}

func _junctions_for_road(junctions: Array, road_index: int) -> Array:
	var result: Array = []
	for junction_variant in junctions:
		var junction: Dictionary = junction_variant
		if int(junction.get("road_a_index", -1)) == road_index or int(junction.get("road_b_index", -1)) == road_index:
			result.append(junction)
	return result


func _road_segment_inside_junction(a: Vector2, b: Vector2, junctions: Array) -> bool:
	var midpoint := (a + b) * 0.5
	for junction_variant in junctions:
		var junction: Dictionary = junction_variant
		var position: Vector2 = junction["position"]
		# Keep a tiny overlap at the circular patch edge, but remove the large coplanar
		# overlap that caused textured roads to flicker from z-fighting.
		var radius: float = float(junction["radius"]) * 0.92
		if midpoint.distance_to(position) <= radius:
			return true
	return false


func _road_segment_overlaps_prior_road(a: Vector2, b: Vector2, width: float, prior_roads: Array) -> bool:
	if prior_roads.is_empty():
		return false
	var midpoint := (a + b) * 0.5
	for prior_variant in prior_roads:
		var prior: Dictionary = prior_variant
		var prior_points: Array = prior.get("points", [])
		if prior_points.size() < 2:
			continue
		var combined_half_width := (width + float(prior.get("width", ROAD_WIDTH))) * 0.5
		# A slightly conservative threshold removes coplanar duplicate road pieces
		# while leaving enough geometry for the junction patch to cover crossings.
		if _distance_to_polyline(midpoint, prior_points) <= combined_half_width * 0.82:
			return true
	return false


func _build_feature_ribbon(terrain: Node3D, feature: Dictionary, feature_type: String, junction_exclusions: Array = [], overlap_roads: Array = []) -> Dictionary:
	var vertices: Array[Vector3] = []
	var normals: Array[Vector3] = []
	var uvs: Array[Vector2] = []
	var raw_points: Array = feature.get("points", [])
	if raw_points.size() < 2:
		return {"vertices": vertices, "normals": normals, "uvs": uvs}

	# Remove duplicate samples first. The old generator built one independent quad
	# per segment; at turns those quads overlapped or opened visually. This builds
	# one ribbon with a shared left/right pair at every path sample instead.
	var points: Array[Vector2] = []
	for point_variant in raw_points:
		var point: Vector2 = point_variant
		if points.is_empty() or points[-1].distance_squared_to(point) > 0.000001:
			points.append(point)
	if points.size() < 2:
		return {"vertices": vertices, "normals": normals, "uvs": uvs}

	if feature_type == "road":
		# Resample long road segments so both road edges query the terrain often
		# enough to conform over hills instead of cutting straight through them.
		points = _resample_road_points_conforming(points)

	var width: float = maxf(float(feature.get("width", ROAD_WIDTH if feature_type == "road" else RIVER_WIDTH)), 0.01)
	var half_width: float = width * 0.5
	var tile_size: float = maxf(float(feature.get("tile_size", 4.0 if feature_type == "road" else 6.0)), 0.001)
	var feature_offset: float = float(terrain.get_meta(META_FEATURE_Y_OFFSET, 0.0))
	var y_offset: float
	if feature_type == "road":
		y_offset = float(feature.get("y_offset", 0.035))
	elif bool(feature.get("preview", false)):
		# Before the river is committed the bed has not been carved yet, so keep
		# the preview just above the surface instead of hiding it underground.
		y_offset = 0.03
	else:
		y_offset = -float(feature.get("surface_drop", 0.15))

	var left_positions: Array[Vector3] = []
	var right_positions: Array[Vector3] = []
	var distances: Array[float] = []
	var accumulated: float = 0.0

	for i in range(points.size()):
		if i > 0:
			accumulated += points[i - 1].distance_to(points[i])
		distances.append(accumulated)

		var offset_vector: Vector2
		if i == 0:
			var first_dir: Vector2 = (points[1] - points[0]).normalized()
			offset_vector = Vector2(-first_dir.y, first_dir.x) * half_width
		elif i == points.size() - 1:
			var last_dir: Vector2 = (points[i] - points[i - 1]).normalized()
			offset_vector = Vector2(-last_dir.y, last_dir.x) * half_width
		else:
			var prev_dir: Vector2 = (points[i] - points[i - 1]).normalized()
			var next_dir: Vector2 = (points[i + 1] - points[i]).normalized()
			var prev_normal := Vector2(-prev_dir.y, prev_dir.x)
			var next_normal := Vector2(-next_dir.y, next_dir.x)
			var miter := prev_normal + next_normal
			if miter.length_squared() <= 0.000001:
				offset_vector = prev_normal * half_width
			else:
				miter = miter.normalized()
				var denominator := miter.dot(prev_normal)
				if absf(denominator) <= 0.15:
					offset_vector = prev_normal * half_width
				else:
					var miter_length := clampf(half_width / denominator, -half_width * 1.65, half_width * 1.65)
					offset_vector = miter * miter_length
		var left_2d := points[i] + offset_vector
		var right_2d := points[i] - offset_vector

		var left_height: float
		var right_height: float
		if feature_type == "river":
			# Water follows the pre-carve surface, then sits below it by Surface Drop.
			# The terrain collision itself uses the carved bed, so rivers remain
			# physically distinct from optional water-surface collision.
			left_height = _sample_uncarved_height(terrain, left_2d)
			right_height = _sample_uncarved_height(terrain, right_2d)
		else:
			left_height = _sample_effective_height(terrain, left_2d)
			right_height = _sample_effective_height(terrain, right_2d)

		left_positions.append(Vector3(left_2d.x, left_height + y_offset + feature_offset, left_2d.y))
		right_positions.append(Vector3(right_2d.x, right_height + y_offset + feature_offset, right_2d.y))

	for i in range(points.size() - 1):
		if feature_type == "road":
			if not junction_exclusions.is_empty() and _road_segment_inside_junction(points[i], points[i + 1], junction_exclusions):
				continue
			if _road_segment_overlaps_prior_road(points[i], points[i + 1], width, overlap_roads):
				continue
		var p0: Vector3 = left_positions[i]
		var p1: Vector3 = right_positions[i]
		var p2: Vector3 = left_positions[i + 1]
		var p3: Vector3 = right_positions[i + 1]
		var u0: float = distances[i] / tile_size
		var u1: float = distances[i + 1] / tile_size
		var v_max: float = width / tile_size
		_add_upward_triangle_uv(vertices, normals, uvs, p0, p1, p3, Vector2(u0, 0.0), Vector2(u0, v_max), Vector2(u1, v_max))
		_add_upward_triangle_uv(vertices, normals, uvs, p0, p3, p2, Vector2(u0, 0.0), Vector2(u1, v_max), Vector2(u1, 0.0))

	return {"vertices": vertices, "normals": normals, "uvs": uvs}

func _add_upward_triangle_uv(vertices: Array, normals: Array, uvs: Array, a: Vector3, b: Vector3, c: Vector3, uv_a: Vector2, uv_b: Vector2, uv_c: Vector2) -> void:
	var desired_normal := _upward_face_normal(a, b, c)
	var cross := (b - a).cross(c - a)
	if cross.length_squared() <= 0.0000001:
		return
	if cross.dot(desired_normal) > 0.0:
		var temp_vertex := b
		b = c
		c = temp_vertex
		var temp_uv := uv_b
		uv_b = uv_c
		uv_c = temp_uv
	vertices.append_array([a, b, c])
	normals.append_array([desired_normal, desired_normal, desired_normal])
	uvs.append_array([uv_a, uv_b, uv_c])


# =============================================================================
# MESH HELPERS
# =============================================================================

func _add_top_triangle(terrain: Node3D, vertices: Array, normals: Array, a: Vector3, b: Vector3, c: Vector3) -> void:
	var normal := _upward_face_normal(a, b, c)
	var up_bias: float = clamp(float(terrain.get_meta(META_TOP_NORMAL_UP_BIAS, 0.0)), 0.0, 1.0)
	if up_bias > 0.0:
		normal = normal.lerp(Vector3.UP, up_bias).normalized()
	_add_oriented_triangle(vertices, normals, a, b, c, normal)

func _add_upward_triangle(vertices: Array, normals: Array, a: Vector3, b: Vector3, c: Vector3) -> void:
	_add_oriented_triangle(vertices, normals, a, b, c, _upward_face_normal(a, b, c))

func _upward_face_normal(a: Vector3, b: Vector3, c: Vector3) -> Vector3:
	var normal := (b - a).cross(c - a).normalized()
	if normal.y < 0.0:
		normal = -normal
	return normal

func _add_oriented_triangle(vertices: Array, normals: Array, a: Vector3, b: Vector3, c: Vector3, desired_normal: Vector3) -> void:
	# IMPORTANT: Godot considers CLOCKWISE triangles front-facing. With the
	# conventional (b-a) x (c-a) cross product, that means a correctly wound
	# front face has its cross product pointing OPPOSITE the desired outward
	# lighting normal. If cross and desired normal point the same way, swap b/c.
	var cross := (b - a).cross(c - a)
	if cross.length_squared() <= 0.0000001:
		return

	var n := desired_normal.normalized()
	if cross.dot(n) > 0.0:
		var temp := b
		b = c
		c = temp

	vertices.append_array([a, b, c])
	normals.append_array([n, n, n])

func _add_triangle_with_normal(vertices: Array, normals: Array, a: Vector3, b: Vector3, c: Vector3, normal: Vector3) -> void:
	_add_oriented_triangle(vertices, normals, a, b, c, normal)

func _add_triangle(vertices: Array, normals: Array, a: Vector3, b: Vector3, c: Vector3) -> void:
	# Generic fallback: convert the mathematical cross-product normal into the
	# outward normal expected by Godot's clockwise winding.
	var cross := (b - a).cross(c - a)
	if cross.length_squared() <= 0.0000001:
		return
	var normal := -cross.normalized()
	_add_oriented_triangle(vertices, normals, a, b, c, normal)

func _add_surface(mesh: ArrayMesh, vertices: Array, normals: Array, material: Material, uvs: Array = []) -> void:
	if vertices.is_empty():
		return

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)

	var packed_vertices := PackedVector3Array(vertices)
	var packed_normals := PackedVector3Array(normals)

	arrays[Mesh.ARRAY_VERTEX] = packed_vertices
	arrays[Mesh.ARRAY_NORMAL] = packed_normals
	if uvs.size() == vertices.size():
		arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array(uvs)

	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	mesh.surface_set_material(mesh.get_surface_count() - 1, material.duplicate())

func _generate_top_uvs(vertices: Array, tile_size: float) -> Array:
	var result: Array[Vector2] = []
	var divisor: float = maxf(tile_size, 0.001)
	for vertex_variant in vertices:
		var vertex: Vector3 = vertex_variant
		result.append(Vector2(vertex.x / divisor, vertex.z / divisor))
	return result

func _generate_cliff_uvs(vertices: Array, normals: Array, tile_size: float) -> Array:
	var result: Array[Vector2] = []
	var divisor: float = maxf(tile_size, 0.001)
	for i in range(vertices.size()):
		var vertex: Vector3 = vertices[i]
		var normal: Vector3 = normals[i] if i < normals.size() else Vector3.FORWARD
		# Project each vertical wall onto its dominant horizontal axis. Using world/local
		# coordinates makes adjacent triangles share the same UV scale and prevents the
		# texture from collapsing to a single sampled color.
		var u: float = vertex.z / divisor if abs(normal.x) > abs(normal.z) else vertex.x / divisor
		var v: float = -vertex.y / divisor
		result.append(Vector2(u, v))
	return result

# =============================================================================
# SAMPLING
# =============================================================================

func _sample_base_height(terrain: Node3D, point: Vector2) -> float:
	var resolution: int = terrain.get_meta(META_RESOLUTION)
	var world_size: float = terrain.get_meta(META_WORLD_SIZE)
	var heights: PackedFloat32Array = terrain.get_meta(META_HEIGHTS)
	var grid := _local_to_grid(point, resolution, world_size)
	
	var x := clamp(int(round(grid.x)), 0, resolution - 1)
	var z := clamp(int(round(grid.y)), 0, resolution - 1)
	return heights[_grid_index(x, z, resolution)]

func _sample_uncarved_height(terrain: Node3D, point: Vector2) -> float:
	var resolution: int = terrain.get_meta(META_RESOLUTION)
	var world_size: float = terrain.get_meta(META_WORLD_SIZE)
	var heights: PackedFloat32Array = terrain.get_meta(META_HEIGHTS)
	var grid := _local_to_grid(point, resolution, world_size)
	var x0: int = clampi(int(floor(grid.x)), 0, resolution - 1)
	var z0: int = clampi(int(floor(grid.y)), 0, resolution - 1)
	var x1: int = mini(x0 + 1, resolution - 1)
	var z1: int = mini(z0 + 1, resolution - 1)
	var tx: float = clampf(grid.x - floor(grid.x), 0.0, 1.0)
	var tz: float = clampf(grid.y - floor(grid.y), 0.0, 1.0)
	var h00: float = heights[_grid_index(x0, z0, resolution)]
	var h10: float = heights[_grid_index(x1, z0, resolution)]
	var h01: float = heights[_grid_index(x0, z1, resolution)]
	var h11: float = heights[_grid_index(x1, z1, resolution)]
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)

func _sample_effective_height(terrain: Node3D, point: Vector2) -> float:
	var resolution: int = terrain.get_meta(META_RESOLUTION)
	var world_size: float = terrain.get_meta(META_WORLD_SIZE)
	var grid := _local_to_grid(point, resolution, world_size)

	var x0 := clamp(int(floor(grid.x)), 0, resolution - 1)
	var z0 := clamp(int(floor(grid.y)), 0, resolution - 1)
	var x1 := min(x0 + 1, resolution - 1)
	var z1 := min(z0 + 1, resolution - 1)

	var tx: float = grid.x - floor(grid.x)
	var tz: float = grid.y - floor(grid.y)

	var h00 := _effective_height_at_grid(terrain, x0, z0)
	var h10 := _effective_height_at_grid(terrain, x1, z0)
	var h01 := _effective_height_at_grid(terrain, x0, z1)
	var h11 := _effective_height_at_grid(terrain, x1, z1)

	return lerp(lerp(h00, h10, tx), lerp(h01, h11, tx), tz)

func _grid_to_local(x: int, z: int, resolution: int, world_size: float) -> Vector3:
	var spacing := world_size / float(resolution - 1)
	var half_size := world_size * 0.5
	return Vector3(float(x) * spacing - half_size, 0.0, float(z) * spacing - half_size)

func _local_to_grid(point: Vector2, resolution: int, world_size: float) -> Vector2:
	var half_size := world_size * 0.5
	return Vector2(
		(point.x + half_size) / world_size * float(resolution - 1),
		(point.y + half_size) / world_size * float(resolution - 1)
	)

func _grid_index(x: int, z: int, resolution: int) -> int:
	return z * resolution + x

func _distance_to_polyline(point: Vector2, points) -> float:
	if points.size() == 0: return INF
	if points.size() == 1: return point.distance_to(points[0])

	var best := INF
	for i in range(points.size() - 1):
		var distance := _distance_to_segment(point, points[i], points[i + 1])
		best = min(best, distance)
	return best

func _distance_to_segment(point: Vector2, a: Vector2, b: Vector2) -> float:
	var ab := b - a
	var length_squared := ab.length_squared()
	if length_squared <= 0.000001:
		return point.distance_to(a)

	var t := clamp((point - a).dot(ab) / length_squared, 0.0, 1.0)
	var closest: Vector2 = a + ab * t
	return point.distance_to(closest)

# =============================================================================
# UNDO / REDO SNAPSHOTS
# =============================================================================

func _capture_snapshot(terrain: Node3D) -> Dictionary:
	_ensure_terrain_material_data(terrain)
	return {
		"resolution": int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION)),
		"world_size": float(terrain.get_meta(META_WORLD_SIZE, DEFAULT_WORLD_SIZE)),
		"mask": (terrain.get_meta(META_MASK) as PackedFloat32Array).duplicate(),
		"heights": (terrain.get_meta(META_HEIGHTS) as PackedFloat32Array).duplicate(),
		"roads": terrain.get_meta(META_ROADS, []).duplicate(true),
		"rivers": terrain.get_meta(META_RIVERS, []).duplicate(true),
		"cell_styles": (terrain.get_meta(META_CELL_STYLES) as PackedInt32Array).duplicate(),
		"cell_active": (terrain.get_meta(META_CELL_ACTIVE, PackedByteArray()) as PackedByteArray).duplicate(),
		"style_palette": terrain.get_meta(META_STYLE_PALETTE, []).duplicate(true),
	}

func _restore_snapshot(terrain: Node3D, snapshot: Dictionary) -> void:
	if not is_instance_valid(terrain): return
	if snapshot.has("resolution"):
		terrain.set_meta(META_RESOLUTION, int(snapshot["resolution"]))
	if snapshot.has("world_size"):
		terrain.set_meta(META_WORLD_SIZE, float(snapshot["world_size"]))
	terrain.set_meta(META_MASK, snapshot["mask"].duplicate())
	terrain.set_meta(META_HEIGHTS, snapshot["heights"].duplicate())
	terrain.set_meta(META_ROADS, snapshot["roads"].duplicate(true))
	terrain.set_meta(META_RIVERS, snapshot["rivers"].duplicate(true))
	if snapshot.has("cell_styles"):
		terrain.set_meta(META_CELL_STYLES, snapshot["cell_styles"].duplicate())
	if snapshot.has("cell_active"):
		terrain.set_meta(META_CELL_ACTIVE, snapshot["cell_active"].duplicate())
	if snapshot.has("style_palette"):
		terrain.set_meta(META_STYLE_PALETTE, snapshot["style_palette"].duplicate(true))
	_generate_terrain_mesh(terrain)

func _snapshots_equal(a: Dictionary, b: Dictionary) -> bool:
	if a.is_empty() or b.is_empty(): return false
	return a.get("resolution", DEFAULT_RESOLUTION) == b.get("resolution", DEFAULT_RESOLUTION) and a.get("world_size", DEFAULT_WORLD_SIZE) == b.get("world_size", DEFAULT_WORLD_SIZE) and a["mask"] == b["mask"] and a["heights"] == b["heights"] and a["roads"] == b["roads"] and a["rivers"] == b["rivers"] and a.get("cell_styles", PackedInt32Array()) == b.get("cell_styles", PackedInt32Array()) and a.get("cell_active", PackedByteArray()) == b.get("cell_active", PackedByteArray()) and a.get("style_palette", []) == b.get("style_palette", [])

# =============================================================================
# LEVEL SAVE / DUPLICATE / DELETE
# =============================================================================

func _create_dialogs() -> void:
	_save_dialog = EditorFileDialog.new()
	_save_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_save_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_save_dialog.current_dir = LEVEL_DIRECTORY
	_save_dialog.add_filter("*.json", "Lowpoly Terrain Level")
	_save_dialog.file_selected.connect(_save_level_to_path)
	get_editor_interface().get_base_control().add_child(_save_dialog)

	_duplicate_dialog = EditorFileDialog.new()
	_duplicate_dialog.file_mode = EditorFileDialog.FILE_MODE_SAVE_FILE
	_duplicate_dialog.access = EditorFileDialog.ACCESS_RESOURCES
	_duplicate_dialog.current_dir = LEVEL_DIRECTORY
	_duplicate_dialog.add_filter("*.json", "Lowpoly Terrain Level")
	_duplicate_dialog.file_selected.connect(_duplicate_level_to_path)
	get_editor_interface().get_base_control().add_child(_duplicate_dialog)

	_delete_dialog = ConfirmationDialog.new()
	_delete_dialog.title = "Delete Level"
	_delete_dialog.dialog_text = "Delete the current terrain level?\n\nThe saved level file will be removed and the terrain node will be removed from the scene."
	_delete_dialog.ok_button_text = "Delete"
	_delete_dialog.confirmed.connect(_delete_current_level)
	get_editor_interface().get_base_control().add_child(_delete_dialog)

func _request_save_level() -> void:
	if not is_instance_valid(_active_terrain): return
	var existing_path: String = _active_terrain.get_meta(META_LEVEL_PATH, "")
	if not existing_path.is_empty():
		_save_level_to_path(existing_path)
		return
	_save_dialog.current_file = _active_terrain.name.to_snake_case() + ".json"
	_save_dialog.popup_centered_ratio(0.65)

func _request_duplicate_level() -> void:
	if not is_instance_valid(_active_terrain): return
	_duplicate_dialog.current_file = _active_terrain.name.to_snake_case() + "_copy.json"
	_duplicate_dialog.popup_centered_ratio(0.65)

func _request_delete_level() -> void:
	if not is_instance_valid(_active_terrain): return
	_delete_dialog.popup_centered()

func _save_level_to_path(path: String) -> void:
	if not is_instance_valid(_active_terrain): return
	if not path.ends_with(".json"): path += ".json"

	var json_data := _serialize_level(_active_terrain)
	var file := FileAccess.open(path, FileAccess.WRITE)
	if not file:
		push_error("Lowpoly Terrain Editor: could not save level: " + path)
		return

	file.store_string(JSON.stringify(json_data, "	"))
	file.close()

	_active_terrain.set_meta(META_LEVEL_PATH, path)
	_status_label.text = "Saved: %s" % path

func _duplicate_level_to_path(path: String) -> void:
	if not is_instance_valid(_active_terrain): return
	if not path.ends_with(".json"): path += ".json"
	
	_save_level_to_path(path)
	var old_name := _active_terrain.name
	var file_name := path.get_file().get_basename()
	_active_terrain.name = file_name
	_status_label.text = "Duplicated %s -> %s" % [old_name, file_name]

func _delete_current_level() -> void:
	if not is_instance_valid(_active_terrain): return
	
	var terrain := _active_terrain
	var level_path: String = terrain.get_meta(META_LEVEL_PATH, "")
	
	if not level_path.is_empty():
		var absolute := ProjectSettings.globalize_path(level_path)
		if FileAccess.file_exists(level_path):
			var error := DirAccess.remove_absolute(absolute)
			if error != OK: push_warning("Could not remove level file: " + level_path)

	var parent := terrain.get_parent()
	if parent: parent.remove_child(terrain)
	terrain.queue_free()

	_active_terrain = null
	_set_tool(ToolMode.NONE)
	_update_toolbar_state()

func _serialize_level(terrain: Node3D) -> Dictionary:
	var mask: PackedFloat32Array = terrain.get_meta(META_MASK)
	var heights: PackedFloat32Array = terrain.get_meta(META_HEIGHTS)
	
	return {
		"version": 1,
		"resolution": terrain.get_meta(META_RESOLUTION),
		"world_size": terrain.get_meta(META_WORLD_SIZE),
		"base_y": terrain.get_meta(META_BASE_Y, DEFAULT_BASE_Y),
		"height_min": terrain.get_meta(META_HEIGHT_MIN, HEIGHT_MIN),
		"height_max": terrain.get_meta(META_HEIGHT_MAX, HEIGHT_MAX),
		"top_y_offset": terrain.get_meta(META_TOP_Y_OFFSET, 0.0),
		"cliff_y_offset": terrain.get_meta(META_CLIFF_Y_OFFSET, 0.0),
		"feature_y_offset": terrain.get_meta(META_FEATURE_Y_OFFSET, 0.0),
		"double_sided": terrain.get_meta(META_DOUBLE_SIDED, false),
		"top_normal_up_bias": terrain.get_meta(META_TOP_NORMAL_UP_BIAS, 0.0),
		"collision_enabled": terrain.get_meta(META_COLLISION_ENABLED, false),
		"collision_layer": terrain.get_meta(META_COLLISION_LAYER, 1),
		"cell_active": Array(terrain.get_meta(META_CELL_ACTIVE, PackedByteArray())),
		"generator_raise_height": terrain.get_meta(META_GENERATOR_RAISE_HEIGHT, 2.0),
		"generator_lower_depth": terrain.get_meta(META_GENERATOR_LOWER_DEPTH, 1.0),
		"generator_color_tolerance": terrain.get_meta(META_GENERATOR_COLOR_TOLERANCE, 0.08),
		"generator_smoothness": terrain.get_meta(META_GENERATOR_SMOOTHNESS, 0.0),
		"generator_clear_features": terrain.get_meta(META_GENERATOR_CLEAR_FEATURES, true),
		"generator_use_single_style": terrain.get_meta(META_GENERATOR_USE_SINGLE_STYLE, true),
		"generator_green_top_color": terrain.get_meta(META_GENERATOR_GREEN_TOP_COLOR, Color(0.44, 0.69, 0.20)),
		"generator_green_cliff_color": terrain.get_meta(META_GENERATOR_GREEN_CLIFF_COLOR, Color(0.45, 0.25, 0.13)),
		"generator_green_top_texture": _resource_path_or_empty(_get_optional_meta(terrain, META_GENERATOR_GREEN_TOP_TEXTURE) as Resource),
		"generator_green_cliff_texture": _resource_path_or_empty(_get_optional_meta(terrain, META_GENERATOR_GREEN_CLIFF_TEXTURE) as Resource),
		"generator_green_top_tile_size": terrain.get_meta(META_GENERATOR_GREEN_TOP_TILE_SIZE, 4.0),
		"generator_green_cliff_tile_size": terrain.get_meta(META_GENERATOR_GREEN_CLIFF_TILE_SIZE, 4.0),
		"generator_red_top_color": terrain.get_meta(META_GENERATOR_RED_TOP_COLOR, Color(0.44, 0.69, 0.20)),
		"generator_red_cliff_color": terrain.get_meta(META_GENERATOR_RED_CLIFF_COLOR, Color(0.45, 0.25, 0.13)),
		"generator_red_top_texture": _resource_path_or_empty(_get_optional_meta(terrain, META_GENERATOR_RED_TOP_TEXTURE) as Resource),
		"generator_red_cliff_texture": _resource_path_or_empty(_get_optional_meta(terrain, META_GENERATOR_RED_CLIFF_TEXTURE) as Resource),
		"generator_red_top_tile_size": terrain.get_meta(META_GENERATOR_RED_TOP_TILE_SIZE, 4.0),
		"generator_red_cliff_tile_size": terrain.get_meta(META_GENERATOR_RED_CLIFF_TILE_SIZE, 4.0),
		"generator_blue_top_color": terrain.get_meta(META_GENERATOR_BLUE_TOP_COLOR, Color(0.44, 0.69, 0.20)),
		"generator_blue_cliff_color": terrain.get_meta(META_GENERATOR_BLUE_CLIFF_COLOR, Color(0.45, 0.25, 0.13)),
		"generator_blue_top_texture": _resource_path_or_empty(_get_optional_meta(terrain, META_GENERATOR_BLUE_TOP_TEXTURE) as Resource),
		"generator_blue_cliff_texture": _resource_path_or_empty(_get_optional_meta(terrain, META_GENERATOR_BLUE_CLIFF_TEXTURE) as Resource),
		"generator_blue_top_tile_size": terrain.get_meta(META_GENERATOR_BLUE_TOP_TILE_SIZE, 4.0),
		"generator_blue_cliff_tile_size": terrain.get_meta(META_GENERATOR_BLUE_CLIFF_TILE_SIZE, 4.0),
		"auto_expand": terrain.get_meta(META_AUTO_EXPAND, true),
		"expand_chunk": terrain.get_meta(META_EXPAND_CHUNK, 8),
		"max_resolution": terrain.get_meta(META_MAX_RESOLUTION, 256),
		"road_width": terrain.get_meta(META_ROAD_WIDTH, ROAD_WIDTH),
		"road_y_offset": terrain.get_meta(META_ROAD_Y_OFFSET, 0.035),
		"road_color": _color_to_array(terrain.get_meta(META_ROAD_COLOR, Color(0.76, 0.56, 0.31))),
		"road_texture": _resource_path_or_empty(_get_optional_meta(terrain, META_ROAD_TEXTURE) as Resource),
		"road_tile_size": terrain.get_meta(META_ROAD_TILE_SIZE, 4.0),
		"road_collision": terrain.get_meta(META_ROAD_COLLISION, true),
		"river_width": terrain.get_meta(META_RIVER_WIDTH, RIVER_WIDTH),
		"river_depth": terrain.get_meta(META_RIVER_DEPTH, RIVER_DEPTH),
		"river_surface_drop": terrain.get_meta(META_RIVER_SURFACE_DROP, 0.15),
		"river_color": _color_to_array(terrain.get_meta(META_RIVER_COLOR, Color(0.12, 0.38, 0.55, 0.72))),
		"river_texture": _resource_path_or_empty(_get_optional_meta(terrain, META_RIVER_TEXTURE) as Resource),
		"river_normal_texture": _resource_path_or_empty(_get_optional_meta(terrain, META_RIVER_NORMAL_TEXTURE) as Resource),
		"river_tile_size": terrain.get_meta(META_RIVER_TILE_SIZE, 6.0),
		"river_roughness": terrain.get_meta(META_RIVER_ROUGHNESS, 0.18),
		"river_normal_strength": terrain.get_meta(META_RIVER_NORMAL_STRENGTH, 0.8),
		"river_refraction": terrain.get_meta(META_RIVER_REFRACTION, 0.012),
		"river_flow_speed": terrain.get_meta(META_RIVER_FLOW_SPEED, 0.03),
		"river_flow_angle": terrain.get_meta(META_RIVER_FLOW_ANGLE, 32.211),
		"river_collision": terrain.get_meta(META_RIVER_COLLISION, false),
		"brush_top_color": _color_to_array(terrain.get_meta(META_BRUSH_TOP_COLOR, Color(0.44, 0.69, 0.20))),
		"brush_cliff_color": _color_to_array(terrain.get_meta(META_BRUSH_CLIFF_COLOR, Color(0.45, 0.25, 0.13))),
		"brush_top_texture": _resource_path_or_empty(_get_optional_meta(terrain, META_BRUSH_TOP_TEXTURE) as Resource),
		"brush_cliff_texture": _resource_path_or_empty(_get_optional_meta(terrain, META_BRUSH_CLIFF_TEXTURE) as Resource),
		"brush_top_tile_size": terrain.get_meta(META_BRUSH_TOP_TILE_SIZE, 4.0),
		"brush_cliff_tile_size": terrain.get_meta(META_BRUSH_CLIFF_TILE_SIZE, 4.0),
		"style_palette": _serialize_style_palette(terrain.get_meta(META_STYLE_PALETTE, [])),
		"cell_styles": Array(terrain.get_meta(META_CELL_STYLES, PackedInt32Array())),
		"mask": Array(mask),
		"heights": Array(heights),
		"roads": _serialize_features(terrain.get_meta(META_ROADS, [])),
		"rivers": _serialize_features(terrain.get_meta(META_RIVERS, [])),
	}

func _serialize_features(features: Array) -> Array:
	var output: Array = []
	for feature_variant in features:
		var feature: Dictionary = feature_variant
		var serialized_points: Array = []
		for point in feature.get("points", []):
			serialized_points.append([point.x, point.y])
		var serialized := feature.duplicate(true)
		serialized["points"] = serialized_points
		if serialized.has("color") and typeof(serialized["color"]) == TYPE_COLOR:
			serialized["color"] = _color_to_array(serialized["color"])
		if serialized.has("texture"):
			serialized["texture_path"] = _resource_path_or_empty(serialized["texture"] as Resource)
			serialized.erase("texture")
		if serialized.has("normal_texture"):
			serialized["normal_texture_path"] = _resource_path_or_empty(serialized["normal_texture"] as Resource)
			serialized.erase("normal_texture")
		output.append(serialized)
	return output

func _ensure_level_directory() -> void:
	var absolute := ProjectSettings.globalize_path(LEVEL_DIRECTORY)
	if not DirAccess.dir_exists_absolute(absolute):
		DirAccess.make_dir_recursive_absolute(absolute)


# =============================================================================
# TERRAIN INSPECTOR TUNING
# =============================================================================

func _install_terrain_inspector_properties(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return

	# Metadata is exposed in the Inspector so each terrain can be tuned independently.
	# These values are also serialized by Godot with the scene.
	if not terrain.has_meta(META_BASE_Y): terrain.set_meta(META_BASE_Y, DEFAULT_BASE_Y)
	if not terrain.has_meta(META_HEIGHT_MIN): terrain.set_meta(META_HEIGHT_MIN, HEIGHT_MIN)
	if not terrain.has_meta(META_HEIGHT_MAX): terrain.set_meta(META_HEIGHT_MAX, HEIGHT_MAX)
	if not terrain.has_meta(META_TOP_Y_OFFSET): terrain.set_meta(META_TOP_Y_OFFSET, 0.0)
	if not terrain.has_meta(META_CLIFF_Y_OFFSET): terrain.set_meta(META_CLIFF_Y_OFFSET, 0.0)
	if not terrain.has_meta(META_FEATURE_Y_OFFSET): terrain.set_meta(META_FEATURE_Y_OFFSET, 0.0)
	if not terrain.has_meta(META_DOUBLE_SIDED): terrain.set_meta(META_DOUBLE_SIDED, false)
	if not terrain.has_meta(META_TOP_NORMAL_UP_BIAS): terrain.set_meta(META_TOP_NORMAL_UP_BIAS, 0.0)
	if not terrain.has_meta(META_BRUSH_TOP_COLOR): terrain.set_meta(META_BRUSH_TOP_COLOR, Color(0.44, 0.69, 0.20))
	if not terrain.has_meta(META_BRUSH_CLIFF_COLOR): terrain.set_meta(META_BRUSH_CLIFF_COLOR, Color(0.45, 0.25, 0.13))
	if not terrain.has_meta(META_BRUSH_TOP_TEXTURE): terrain.set_meta(META_BRUSH_TOP_TEXTURE, null)
	if not terrain.has_meta(META_BRUSH_CLIFF_TEXTURE): terrain.set_meta(META_BRUSH_CLIFF_TEXTURE, null)
	if not terrain.has_meta(META_BRUSH_TOP_TILE_SIZE): terrain.set_meta(META_BRUSH_TOP_TILE_SIZE, 4.0)
	if not terrain.has_meta(META_BRUSH_CLIFF_TILE_SIZE): terrain.set_meta(META_BRUSH_CLIFF_TILE_SIZE, 4.0)
	if not terrain.has_meta(META_COLLISION_ENABLED): terrain.set_meta(META_COLLISION_ENABLED, false)
	if not terrain.has_meta(META_COLLISION_LAYER): terrain.set_meta(META_COLLISION_LAYER, 1)
	if not terrain.has_meta(META_AUTO_EXPAND): terrain.set_meta(META_AUTO_EXPAND, true)
	if not terrain.has_meta(META_EXPAND_CHUNK): terrain.set_meta(META_EXPAND_CHUNK, 8)
	if not terrain.has_meta(META_MAX_RESOLUTION): terrain.set_meta(META_MAX_RESOLUTION, 256)
	if not terrain.has_meta(META_GENERATOR_RAISE_HEIGHT): terrain.set_meta(META_GENERATOR_RAISE_HEIGHT, 2.0)
	if not terrain.has_meta(META_GENERATOR_LOWER_DEPTH): terrain.set_meta(META_GENERATOR_LOWER_DEPTH, 1.0)
	if not terrain.has_meta(META_GENERATOR_COLOR_TOLERANCE): terrain.set_meta(META_GENERATOR_COLOR_TOLERANCE, 0.08)
	if not terrain.has_meta(META_GENERATOR_SMOOTHNESS): terrain.set_meta(META_GENERATOR_SMOOTHNESS, 0.0)
	if not terrain.has_meta(META_GENERATOR_CLEAR_FEATURES): terrain.set_meta(META_GENERATOR_CLEAR_FEATURES, true)
	if not terrain.has_meta(META_GENERATOR_USE_SINGLE_STYLE): terrain.set_meta(META_GENERATOR_USE_SINGLE_STYLE, true)
	_ensure_generator_style_defaults(terrain)
	if not terrain.has_meta(META_ROAD_WIDTH): terrain.set_meta(META_ROAD_WIDTH, ROAD_WIDTH)
	if not terrain.has_meta(META_ROAD_Y_OFFSET): terrain.set_meta(META_ROAD_Y_OFFSET, 0.035)
	if not terrain.has_meta(META_ROAD_COLOR): terrain.set_meta(META_ROAD_COLOR, Color(0.76, 0.56, 0.31))
	if not terrain.has_meta(META_ROAD_TILE_SIZE): terrain.set_meta(META_ROAD_TILE_SIZE, 4.0)
	if not terrain.has_meta(META_ROAD_COLLISION): terrain.set_meta(META_ROAD_COLLISION, true)
	if not terrain.has_meta(META_RIVER_WIDTH): terrain.set_meta(META_RIVER_WIDTH, RIVER_WIDTH)
	if not terrain.has_meta(META_RIVER_DEPTH): terrain.set_meta(META_RIVER_DEPTH, RIVER_DEPTH)
	if not terrain.has_meta(META_RIVER_SURFACE_DROP): terrain.set_meta(META_RIVER_SURFACE_DROP, 0.15)
	if not terrain.has_meta(META_RIVER_COLOR): terrain.set_meta(META_RIVER_COLOR, Color(0.12, 0.38, 0.55, 0.72))
	if not terrain.has_meta(META_RIVER_TILE_SIZE): terrain.set_meta(META_RIVER_TILE_SIZE, 6.0)
	if not terrain.has_meta(META_RIVER_ROUGHNESS): terrain.set_meta(META_RIVER_ROUGHNESS, 0.18)
	if not terrain.has_meta(META_RIVER_NORMAL_STRENGTH): terrain.set_meta(META_RIVER_NORMAL_STRENGTH, 0.8)
	if not terrain.has_meta(META_RIVER_REFRACTION): terrain.set_meta(META_RIVER_REFRACTION, 0.012)
	if not terrain.has_meta(META_RIVER_FLOW_SPEED): terrain.set_meta(META_RIVER_FLOW_SPEED, 0.03)
	if not terrain.has_meta(META_RIVER_COLLISION): terrain.set_meta(META_RIVER_COLLISION, false)
	_ensure_terrain_material_data(terrain)

	if not terrain.has_meta(META_CELL_ACTIVE):
		var migrate_resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
		var migrate_mask: PackedFloat32Array = terrain.get_meta(META_MASK, PackedFloat32Array())
		var migrate_cells := PackedByteArray()
		migrate_cells.resize(maxi(0, (migrate_resolution - 1) * (migrate_resolution - 1)))
		migrate_cells.fill(0)
		if migrate_mask.size() == migrate_resolution * migrate_resolution:
			for z in range(migrate_resolution - 1):
				for x in range(migrate_resolution - 1):
					migrate_cells[_cell_style_index(x, z, migrate_resolution)] = 1 if _cell_active_for_mask(migrate_mask, x, z, migrate_resolution) else 0
		terrain.set_meta(META_CELL_ACTIVE, migrate_cells)

	# One-time migration from the earlier workaround. Back-face culling is the
	# correct default now that every generated triangle has deterministic winding.
	var winding_version: int = int(terrain.get_meta(META_WINDING_VERSION, 0))
	if winding_version < CURRENT_WINDING_VERSION:
		terrain.set_meta(META_DOUBLE_SIDED, false)
		terrain.set_meta(META_WINDING_VERSION, CURRENT_WINDING_VERSION)

func _sync_material_cull_mode(terrain: Node3D) -> void:
	var double_sided: bool = terrain.get_meta(META_DOUBLE_SIDED, false)
	var mode := BaseMaterial3D.CULL_DISABLED if double_sided else BaseMaterial3D.CULL_BACK
	_top_material.cull_mode = mode
	_cliff_material.cull_mode = mode
	_road_material.cull_mode = mode
	_river_material.cull_mode = mode

func _set_tuning_meta(terrain: Node3D, key: String, value: Variant) -> void:
	if not is_instance_valid(terrain):
		return
	terrain.set_meta(key, value)

	if key == META_HEIGHT_MIN or key == META_HEIGHT_MAX:
		var min_height := _terrain_height_min(terrain)
		var max_height := _terrain_height_max(terrain)
		var heights: PackedFloat32Array = terrain.get_meta(META_HEIGHTS, PackedFloat32Array())
		for i in range(heights.size()):
			heights[i] = clampf(heights[i], min_height, max_height)
		terrain.set_meta(META_HEIGHTS, heights)

	_last_tuning_signature = ""
	_generate_terrain_mesh(terrain)
	terrain.notify_property_list_changed()

func _terrain_tuning_signature(terrain: Node3D) -> String:
	return "%s|%s|%s|%s|%s|%s|%s|%s|%s|%s" % [
		terrain.get_meta(META_BASE_Y, DEFAULT_BASE_Y),
		terrain.get_meta(META_HEIGHT_MIN, HEIGHT_MIN),
		terrain.get_meta(META_HEIGHT_MAX, HEIGHT_MAX),
		terrain.get_meta(META_TOP_Y_OFFSET, 0.0),
		terrain.get_meta(META_CLIFF_Y_OFFSET, 0.0),
		terrain.get_meta(META_FEATURE_Y_OFFSET, 0.0),
		terrain.get_meta(META_DOUBLE_SIDED, false),
		terrain.get_meta(META_TOP_NORMAL_UP_BIAS, 0.0),
		terrain.get_meta(META_COLLISION_ENABLED, false),
		terrain.get_meta(META_COLLISION_LAYER, 1),
	]

# =============================================================================
# PROCEDURAL PIXEL-MAP GENERATOR
# =============================================================================

func _set_generator_setting(terrain: Node3D, key: String, value: Variant) -> void:
	if not is_instance_valid(terrain):
		return
	if value == null:
		if terrain.has_meta(key):
			terrain.remove_meta(key)
	else:
		terrain.set_meta(key, value)

	# Generator controls are fully custom Inspector widgets, so changing a color,
	# texture, tile size or toggle does not require rebuilding the Inspector.
	# Avoiding notify_property_list_changed() here also prevents resource/color
	# edits from needlessly disturbing the current UI state.

func _generator_style_keys(prefix: String) -> Dictionary:
	return {
		"top_color": "_lte_generator_%s_top_color" % prefix,
		"cliff_color": "_lte_generator_%s_cliff_color" % prefix,
		"top_texture": "_lte_generator_%s_top_texture" % prefix,
		"cliff_texture": "_lte_generator_%s_cliff_texture" % prefix,
		"top_tile_size": "_lte_generator_%s_top_tile_size" % prefix,
		"cliff_tile_size": "_lte_generator_%s_cliff_tile_size" % prefix,
	}

func _ensure_generator_style_defaults(terrain: Node3D) -> void:
	var current_top_color: Color = terrain.get_meta(META_BRUSH_TOP_COLOR, Color(0.44, 0.69, 0.20))
	var current_cliff_color: Color = terrain.get_meta(META_BRUSH_CLIFF_COLOR, Color(0.45, 0.25, 0.13))
	var current_top_texture := _get_optional_meta(terrain, META_BRUSH_TOP_TEXTURE) as Texture2D
	var current_cliff_texture := _get_optional_meta(terrain, META_BRUSH_CLIFF_TEXTURE) as Texture2D
	var current_top_tile: float = float(terrain.get_meta(META_BRUSH_TOP_TILE_SIZE, 4.0))
	var current_cliff_tile: float = float(terrain.get_meta(META_BRUSH_CLIFF_TILE_SIZE, 4.0))

	for prefix in ["green", "red", "blue"]:
		var keys := _generator_style_keys(prefix)
		if not terrain.has_meta(keys["top_color"]): terrain.set_meta(keys["top_color"], current_top_color)
		if not terrain.has_meta(keys["cliff_color"]): terrain.set_meta(keys["cliff_color"], current_cliff_color)
		if not terrain.has_meta(keys["top_texture"]) and current_top_texture != null: terrain.set_meta(keys["top_texture"], current_top_texture)
		if not terrain.has_meta(keys["cliff_texture"]) and current_cliff_texture != null: terrain.set_meta(keys["cliff_texture"], current_cliff_texture)
		if not terrain.has_meta(keys["top_tile_size"]): terrain.set_meta(keys["top_tile_size"], current_top_tile)
		if not terrain.has_meta(keys["cliff_tile_size"]): terrain.set_meta(keys["cliff_tile_size"], current_cliff_tile)

func _copy_current_paint_to_generator_styles(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return

	var top_color: Color = terrain.get_meta(META_BRUSH_TOP_COLOR, Color(0.44, 0.69, 0.20))
	var cliff_color: Color = terrain.get_meta(META_BRUSH_CLIFF_COLOR, Color(0.45, 0.25, 0.13))
	var top_texture := _get_optional_meta(terrain, META_BRUSH_TOP_TEXTURE) as Texture2D
	var cliff_texture := _get_optional_meta(terrain, META_BRUSH_CLIFF_TEXTURE) as Texture2D
	var top_tile: float = float(terrain.get_meta(META_BRUSH_TOP_TILE_SIZE, 4.0))
	var cliff_tile: float = float(terrain.get_meta(META_BRUSH_CLIFF_TILE_SIZE, 4.0))

	for prefix in ["green", "red", "blue"]:
		var keys := _generator_style_keys(prefix)
		terrain.set_meta(keys["top_color"], top_color)
		terrain.set_meta(keys["cliff_color"], cliff_color)
		if top_texture == null:
			if terrain.has_meta(keys["top_texture"]): terrain.remove_meta(keys["top_texture"])
		else:
			terrain.set_meta(keys["top_texture"], top_texture)
		if cliff_texture == null:
			if terrain.has_meta(keys["cliff_texture"]): terrain.remove_meta(keys["cliff_texture"])
		else:
			terrain.set_meta(keys["cliff_texture"], cliff_texture)
		terrain.set_meta(keys["top_tile_size"], top_tile)
		terrain.set_meta(keys["cliff_tile_size"], cliff_tile)

	terrain.notify_property_list_changed()

func _capture_generator_style(terrain: Node3D, prefix: String) -> int:
	var keys := _generator_style_keys(prefix)
	return _capture_style_definition(
		terrain,
		terrain.get_meta(keys["top_color"], Color(0.44, 0.69, 0.20)),
		terrain.get_meta(keys["cliff_color"], Color(0.45, 0.25, 0.13)),
		_get_optional_meta(terrain, keys["top_texture"]) as Texture2D,
		_get_optional_meta(terrain, keys["cliff_texture"]) as Texture2D,
		maxf(float(terrain.get_meta(keys["top_tile_size"], 4.0)), 0.001),
		maxf(float(terrain.get_meta(keys["cliff_tile_size"], 4.0)), 0.001)
	)

func _generate_from_image(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return

	var texture := _get_optional_meta(terrain, META_GENERATOR_IMAGE) as Texture2D
	if texture == null:
		push_warning("Lowpoly Terrain Editor: assign a Source Pixel Map before generating.")
		return

	var image: Image = texture.get_image()
	if image == null or image.is_empty():
		push_warning("Lowpoly Terrain Editor: could not read pixels from the assigned Source Pixel Map.")
		return

	var width: int = image.get_width()
	var height: int = image.get_height()
	if width < 1 or height < 1 or width > 256 or height > 256:
		push_warning("Lowpoly Terrain Editor: source image must be between 1x1 and 256x256 pixels. Got %dx%d." % [width, height])
		return

	var before := _capture_snapshot(terrain)
	_apply_image_generation(terrain, image)
	var after := _capture_snapshot(terrain)

	if _snapshots_equal(before, after):
		return

	var undo_redo := get_undo_redo()
	undo_redo.create_action("Lowpoly Terrain: Generate from Image", UndoRedo.MERGE_DISABLE, terrain)
	undo_redo.add_do_method(self, "_restore_snapshot", terrain, after)
	undo_redo.add_undo_method(self, "_restore_snapshot", terrain, before)
	undo_redo.commit_action(false)

func _apply_image_generation(terrain: Node3D, image: Image) -> void:
	_ensure_terrain_material_data(terrain)

	var width: int = image.get_width()
	var height: int = image.get_height()
	var side_cells: int = maxi(width, height)
	var resolution: int = side_cells + 1
	var world_size: float = float(side_cells)
	var offset_x: int = (side_cells - width) / 2
	var offset_z: int = (side_cells - height) / 2

	var raise_height: float = clampf(float(terrain.get_meta(META_GENERATOR_RAISE_HEIGHT, 2.0)), 0.0, maxf(0.0, _terrain_height_max(terrain)))
	var lower_depth: float = maxf(0.0, float(terrain.get_meta(META_GENERATOR_LOWER_DEPTH, 1.0)))
	var lower_height: float = clampf(-lower_depth, _terrain_height_min(terrain), 0.0)
	var tolerance: float = clampf(float(terrain.get_meta(META_GENERATOR_COLOR_TOLERANCE, 0.08)), 0.0, 0.5)
	var generator_smoothness: float = clampf(float(terrain.get_meta(META_GENERATOR_SMOOTHNESS, 0.0)), 0.0, 32.0)

	var cell_active := PackedByteArray()
	cell_active.resize(side_cells * side_cells)
	cell_active.fill(0)

	var desired_cell_heights := PackedFloat32Array()
	desired_cell_heights.resize(side_cells * side_cells)
	desired_cell_heights.fill(0.0)

	var use_single_style: bool = bool(terrain.get_meta(META_GENERATOR_USE_SINGLE_STYLE, true))
	var shared_style_id: int = _capture_current_paint_style(terrain)
	var green_style_id: int = shared_style_id if use_single_style else _capture_generator_style(terrain, "green")
	var red_style_id: int = shared_style_id if use_single_style else _capture_generator_style(terrain, "red")
	var blue_style_id: int = shared_style_id if use_single_style else _capture_generator_style(terrain, "blue")

	var cell_styles := PackedInt32Array()
	cell_styles.resize(side_cells * side_cells)
	cell_styles.fill(-1)

	var unknown_count := 0
	var green_count := 0
	var red_count := 0
	var blue_count := 0

	for image_y in range(height):
		for image_x in range(width):
			var pixel: Color = image.get_pixel(image_x, image_y)
			var classification: int = _classify_generator_pixel(pixel, tolerance)
			var cell_x: int = offset_x + image_x
			var cell_z: int = offset_z + image_y
			var cell_index: int = cell_z * side_cells + cell_x

			match classification:
				0:
					pass
				1:
					cell_active[cell_index] = 1
					cell_styles[cell_index] = green_style_id
					desired_cell_heights[cell_index] = 0.0
					green_count += 1
				2:
					cell_active[cell_index] = 1
					cell_styles[cell_index] = red_style_id
					desired_cell_heights[cell_index] = raise_height
					red_count += 1
				3:
					cell_active[cell_index] = 1
					cell_styles[cell_index] = blue_style_id
					desired_cell_heights[cell_index] = lower_height
					blue_count += 1
				_:
					unknown_count += 1

	# Smooth semantic RED/BLUE regions before converting cell targets to shared
	# grid vertices. Large regions keep their requested peak/depth in the interior;
	# small regions naturally become rounded hills or dents.
	desired_cell_heights = _smooth_generator_cell_heights(cell_active, desired_cell_heights, side_cells, generator_smoothness)

	# Neighboring cells share terrain vertices. Average the requested heights of
	# active cells touching each vertex so red/green/blue boundaries become clean,
	# editable low-poly slopes instead of cracked duplicate geometry.
	var heights := PackedFloat32Array()
	heights.resize(resolution * resolution)
	heights.fill(0.0)

	var mask := PackedFloat32Array()
	mask.resize(resolution * resolution)
	mask.fill(0.0)

	for vz in range(resolution):
		for vx in range(resolution):
			var sum_height := 0.0
			var active_neighbors := 0
			for dz in range(-1, 1):
				for dx in range(-1, 1):
					var cx: int = vx + dx
					var cz: int = vz + dz
					if cx < 0 or cz < 0 or cx >= side_cells or cz >= side_cells:
						continue
					var ci: int = cz * side_cells + cx
					if cell_active[ci] == 0:
						continue
					sum_height += desired_cell_heights[ci]
					active_neighbors += 1

			var vertex_index: int = _grid_index(vx, vz, resolution)
			if active_neighbors > 0:
				heights[vertex_index] = sum_height / float(active_neighbors)
				mask[vertex_index] = 1.0

	terrain.set_meta(META_RESOLUTION, resolution)
	terrain.set_meta(META_WORLD_SIZE, world_size)
	terrain.set_meta(META_MASK, mask)
	terrain.set_meta(META_HEIGHTS, heights)
	terrain.set_meta(META_CELL_ACTIVE, cell_active)
	terrain.set_meta(META_CELL_STYLES, cell_styles)
	terrain.set_meta(META_MAX_RESOLUTION, maxi(int(terrain.get_meta(META_MAX_RESOLUTION, 256)), resolution))

	if bool(terrain.get_meta(META_GENERATOR_CLEAR_FEATURES, true)):
		terrain.set_meta(META_ROADS, [])
		terrain.set_meta(META_RIVERS, [])

	_generate_terrain_mesh(terrain)
	terrain.notify_property_list_changed()

	if unknown_count > 0:
		push_warning("Lowpoly Terrain Editor: %d pixel(s) did not match white/green/red/blue within tolerance and were treated as empty." % unknown_count)

	if _status_label:
		_status_label.text = "Generated %dx%d | G:%d R:%d B:%d" % [width, height, green_count, red_count, blue_count]

func _smooth_generator_cell_heights(
	cell_active: PackedByteArray,
	desired: PackedFloat32Array,
	side_cells: int,
	smoothness: float
) -> PackedFloat32Array:
	if smoothness <= 0.001 or side_cells <= 0:
		return desired.duplicate()

	var positive_distance := PackedInt32Array()
	var negative_distance := PackedInt32Array()
	positive_distance.resize(side_cells * side_cells)
	negative_distance.resize(side_cells * side_cells)
	var far := side_cells * 4 + 1024

	for z in range(side_cells):
		for x in range(side_cells):
			var index := z * side_cells + x
			var value := desired[index] if cell_active[index] != 0 else 0.0
			positive_distance[index] = far if value > 0.0001 else 0
			negative_distance[index] = far if value < -0.0001 else 0

	# Two-pass Manhattan distance transform. It measures distance inside each
	# raised/indented semantic region to the nearest different/empty cell.
	for z in range(side_cells):
		for x in range(side_cells):
			var index := z * side_cells + x
			if x > 0:
				positive_distance[index] = mini(positive_distance[index], positive_distance[index - 1] + 1)
				negative_distance[index] = mini(negative_distance[index], negative_distance[index - 1] + 1)
			if z > 0:
				positive_distance[index] = mini(positive_distance[index], positive_distance[index - side_cells] + 1)
				negative_distance[index] = mini(negative_distance[index], negative_distance[index - side_cells] + 1)

	for z in range(side_cells - 1, -1, -1):
		for x in range(side_cells - 1, -1, -1):
			var index := z * side_cells + x
			if x < side_cells - 1:
				positive_distance[index] = mini(positive_distance[index], positive_distance[index + 1] + 1)
				negative_distance[index] = mini(negative_distance[index], negative_distance[index + 1] + 1)
			if z < side_cells - 1:
				positive_distance[index] = mini(positive_distance[index], positive_distance[index + side_cells] + 1)
				negative_distance[index] = mini(negative_distance[index], negative_distance[index + side_cells] + 1)

	var result := desired.duplicate()
	for index in range(result.size()):
		if cell_active[index] == 0:
			continue
		var value := desired[index]
		if absf(value) <= 0.0001:
			continue
		var distance: float = float(positive_distance[index] if value > 0.0 else negative_distance[index])
		var factor := clampf(distance / maxf(smoothness, 0.001), 0.0, 1.0)
		factor = smoothstep(0.0, 1.0, factor)
		result[index] = value * factor
	return result


func _classify_generator_pixel(color: Color, tolerance: float) -> int:
	if color.a <= 0.01:
		return 0

	var references := [
		Color(1.0, 1.0, 1.0),
		Color(0.0, 1.0, 0.0),
		Color(1.0, 0.0, 0.0),
		Color(0.0, 0.0, 1.0),
	]

	var best_index := -1
	var best_error := INF
	for i in range(references.size()):
		var reference: Color = references[i]
		var error: float = maxf(absf(color.r - reference.r), maxf(absf(color.g - reference.g), absf(color.b - reference.b)))
		if error < best_error:
			best_error = error
			best_index = i

	if best_error > tolerance:
		return -1
	return best_index

func _sync_cell_active_near_brush(
	terrain: Node3D,
	target_pos: Vector2,
	brush_radius: float,
	allow_activation: bool = true
) -> PackedInt32Array:
	var activated := PackedInt32Array()
	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	if resolution < 2:
		return activated

	var world_size: float = float(terrain.get_meta(META_WORLD_SIZE, DEFAULT_WORLD_SIZE))
	var mask: PackedFloat32Array = terrain.get_meta(META_MASK)
	var cells: PackedByteArray = terrain.get_meta(META_CELL_ACTIVE, PackedByteArray())
	var expected_size: int = (resolution - 1) * (resolution - 1)

	if cells.size() != expected_size:
		cells.resize(expected_size)
		cells.fill(0)

	var spacing: float = world_size / float(resolution - 1)
	var influence: float = brush_radius + spacing * 1.5
	var bounds := _brush_vertex_bounds(terrain, target_pos, influence, 1)
	var min_x: int = clampi(int(bounds["min_x"]) - 1, 0, resolution - 2)
	var max_x: int = clampi(int(bounds["max_x"]), 0, resolution - 2)
	var min_z: int = clampi(int(bounds["min_z"]) - 1, 0, resolution - 2)
	var max_z: int = clampi(int(bounds["max_z"]), 0, resolution - 2)

	for z in range(min_z, max_z + 1):
		for x in range(min_x, max_x + 1):
			var a := _grid_to_local(x, z, resolution, world_size)
			var b := _grid_to_local(x + 1, z + 1, resolution, world_size)
			var center := Vector2((a.x + b.x) * 0.5, (a.z + b.z) * 0.5)
			if center.distance_to(target_pos) > influence:
				continue

			var index: int = _cell_style_index(x, z, resolution)
			var was_active: bool = cells[index] != 0
			var mask_active: bool = _cell_active_for_mask(mask, x, z, resolution)

			if allow_activation:
				cells[index] = 1 if mask_active else 0
				if not was_active and mask_active:
					activated.append(index)
			else:
				if was_active and not mask_active:
					cells[index] = 0

	terrain.set_meta(META_CELL_ACTIVE, cells)
	return activated


func _assign_style_to_cell_indices(terrain: Node3D, indices: PackedInt32Array) -> void:
	if indices.is_empty():
		return

	_ensure_terrain_material_data(terrain)
	var cell_styles: PackedInt32Array = terrain.get_meta(META_CELL_STYLES, PackedInt32Array())
	if cell_styles.is_empty():
		return

	var style_id: int = _capture_current_paint_style(terrain)
	for index in indices:
		if index >= 0 and index < cell_styles.size():
			cell_styles[index] = style_id
	terrain.set_meta(META_CELL_STYLES, cell_styles)


# =============================================================================
# EXPANDABLE TERRAIN CANVAS
# =============================================================================

func _set_canvas_setting(terrain: Node3D, key: String, value: Variant) -> void:
	if not is_instance_valid(terrain):
		return
	terrain.set_meta(key, value)
	terrain.notify_property_list_changed()

func _grow_canvas_from_inspector(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return
	var chunk: int = maxi(1, int(terrain.get_meta(META_EXPAND_CHUNK, 8)))
	var max_resolution: int = maxi(64, int(terrain.get_meta(META_MAX_RESOLUTION, 256)))
	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	var allowed_per_side: int = maxi(0, (max_resolution - resolution) / 2)
	var cells_per_side: int = mini(chunk, allowed_per_side)
	if cells_per_side <= 0:
		push_warning("Lowpoly Terrain Editor: Maximum Resolution reached. Increase Maximum Resolution to grow the canvas further.")
		return
	_expand_terrain_grid(terrain, cells_per_side)
	_generate_terrain_mesh(terrain)
	_last_tuning_signature = ""
	terrain.notify_property_list_changed()

func _ensure_canvas_for_paint(terrain: Node3D, local_position: Vector3) -> bool:
	if not bool(terrain.get_meta(META_AUTO_EXPAND, true)):
		return false

	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	var world_size: float = float(terrain.get_meta(META_WORLD_SIZE, DEFAULT_WORLD_SIZE))
	if resolution < 2:
		return false

	var spacing: float = world_size / float(resolution - 1)
	var half_size: float = world_size * 0.5
	var required_half: float = maxf(absf(local_position.x), absf(local_position.z)) + _brush_radius + spacing

	if required_half <= half_size:
		return false

	var needed_per_side: int = int(ceil((required_half - half_size) / spacing))
	var chunk: int = maxi(1, int(terrain.get_meta(META_EXPAND_CHUNK, 8)))
	var chunks_needed: int = int(ceil(float(needed_per_side) / float(chunk)))
	var requested_per_side: int = maxi(chunk, chunks_needed * chunk)

	var max_resolution: int = maxi(64, int(terrain.get_meta(META_MAX_RESOLUTION, 256)))
	var allowed_per_side: int = maxi(0, (max_resolution - resolution) / 2)
	var cells_per_side: int = mini(requested_per_side, allowed_per_side)

	if cells_per_side <= 0:
		if not _max_expand_warned_this_stroke:
			push_warning("Lowpoly Terrain Editor: Paint reached the configured Maximum Resolution (%d). Increase Maximum Resolution to continue expanding." % max_resolution)
			_max_expand_warned_this_stroke = true
		return false

	_expand_terrain_grid(terrain, cells_per_side)
	terrain.notify_property_list_changed()
	return true

func _expand_terrain_grid(terrain: Node3D, cells_per_side: int) -> void:
	if cells_per_side <= 0:
		return

	_ensure_terrain_material_data(terrain)

	var old_resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	var old_world_size: float = float(terrain.get_meta(META_WORLD_SIZE, DEFAULT_WORLD_SIZE))
	if old_resolution < 2:
		return

	var spacing: float = old_world_size / float(old_resolution - 1)
	var new_resolution: int = old_resolution + cells_per_side * 2
	var new_world_size: float = old_world_size + float(cells_per_side * 2) * spacing

	var old_mask: PackedFloat32Array = terrain.get_meta(META_MASK)
	var old_heights: PackedFloat32Array = terrain.get_meta(META_HEIGHTS)
	var old_styles: PackedInt32Array = terrain.get_meta(META_CELL_STYLES, PackedInt32Array())
	var old_active: PackedByteArray = terrain.get_meta(META_CELL_ACTIVE, PackedByteArray())

	var new_mask := PackedFloat32Array()
	new_mask.resize(new_resolution * new_resolution)
	new_mask.fill(0.0)

	var new_heights := PackedFloat32Array()
	new_heights.resize(new_resolution * new_resolution)
	new_heights.fill(0.0)

	# Copy old vertex samples into the centered larger grid. Because world size
	# grows by exactly the same number of cell spacings, every old vertex keeps
	# the exact same local/world X/Z position.
	for z in range(old_resolution):
		for x in range(old_resolution):
			var old_index: int = _grid_index(x, z, old_resolution)
			var new_index: int = _grid_index(x + cells_per_side, z + cells_per_side, new_resolution)
			new_mask[new_index] = old_mask[old_index]
			new_heights[new_index] = old_heights[old_index]

	var new_styles := PackedInt32Array()
	new_styles.resize((new_resolution - 1) * (new_resolution - 1))
	new_styles.fill(-1)

	var new_active := PackedByteArray()
	new_active.resize((new_resolution - 1) * (new_resolution - 1))
	new_active.fill(0)

	if old_styles.size() == (old_resolution - 1) * (old_resolution - 1):
		for z in range(old_resolution - 1):
			for x in range(old_resolution - 1):
				var old_style_index: int = _cell_style_index(x, z, old_resolution)
				var new_style_index: int = _cell_style_index(x + cells_per_side, z + cells_per_side, new_resolution)
				new_styles[new_style_index] = old_styles[old_style_index]
				if old_active.size() == (old_resolution - 1) * (old_resolution - 1):
					new_active[new_style_index] = old_active[old_style_index]

	terrain.set_meta(META_RESOLUTION, new_resolution)
	terrain.set_meta(META_WORLD_SIZE, new_world_size)
	terrain.set_meta(META_MASK, new_mask)
	terrain.set_meta(META_HEIGHTS, new_heights)
	terrain.set_meta(META_CELL_STYLES, new_styles)
	terrain.set_meta(META_CELL_ACTIVE, new_active)

# =============================================================================
# PER-CELL MATERIAL PAINTING / COLLISION
# =============================================================================

func _get_optional_meta(object: Object, key: StringName) -> Variant:
	# Godot treats null metadata as absent metadata. Calling get_meta() for an
	# absent optional texture can print an editor error, so always guard it.
	return object.get_meta(key) if object.has_meta(key) else null

func _set_paint_setting(terrain: Node3D, key: String, value: Variant) -> void:
	if not is_instance_valid(terrain):
		return
	if value == null:
		if terrain.has_meta(key):
			terrain.remove_meta(key)
	else:
		terrain.set_meta(key, value)
	# Deliberately do NOT regenerate/re-style existing geometry here. These values
	# are brush settings and are captured only when a cell transitions to painted.

func _set_feature_setting_and_refresh(terrain: Node3D, key: String, value: Variant) -> void:
	_set_feature_setting(terrain, key, value)
	if is_instance_valid(terrain):
		terrain.notify_property_list_changed()

func _create_editable_water_normal(terrain: Node3D) -> void:
	if not is_instance_valid(terrain):
		return
	var noise := FastNoiseLite.new()
	noise.frequency = 0.035
	noise.fractal_octaves = 4
	var texture := NoiseTexture2D.new()
	texture.width = 256
	texture.height = 256
	texture.seamless = true
	texture.as_normal_map = true
	texture.noise = noise
	terrain.set_meta(META_RIVER_NORMAL_TEXTURE, texture)
	terrain.notify_property_list_changed()

func _ensure_fast_noise_on_water_texture(terrain: Node3D, texture: NoiseTexture2D) -> void:
	if not is_instance_valid(terrain) or texture == null:
		return
	if texture.noise == null:
		var noise := FastNoiseLite.new()
		noise.frequency = 0.035
		noise.fractal_octaves = 4
		texture.noise = noise
	terrain.notify_property_list_changed()

func _set_feature_setting(terrain: Node3D, key: String, value: Variant) -> void:
	if not is_instance_valid(terrain):
		return
	if value == null:
		if terrain.has_meta(key):
			terrain.remove_meta(key)
	else:
		terrain.set_meta(key, value)
	# These are brush settings. Existing committed roads/rivers retain the style
	# dictionary captured when their stroke ended.

func _make_default_style() -> Dictionary:
	return {
		"top_color": Color(0.44, 0.69, 0.20),
		"cliff_color": Color(0.45, 0.25, 0.13),
		"top_texture": null,
		"cliff_texture": null,
		"top_tile_size": 4.0,
		"cliff_tile_size": 4.0,
		"signature": _paint_style_signature(Color(0.44, 0.69, 0.20), Color(0.45, 0.25, 0.13), null, null, 4.0, 4.0),
	}

func _ensure_terrain_material_data(terrain: Node3D) -> void:
	var resolution: int = terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION)
	var cell_count := (resolution - 1) * (resolution - 1)

	var palette: Array = terrain.get_meta(META_STYLE_PALETTE, [])
	if palette.is_empty():
		palette = [_make_default_style()]
	else:
		for i in range(palette.size()):
			palette[i] = _migrate_style_texture_fields(palette[i])
	terrain.set_meta(META_STYLE_PALETTE, palette)

	var cell_styles: PackedInt32Array = terrain.get_meta(META_CELL_STYLES, PackedInt32Array())
	if cell_styles.size() != cell_count:
		cell_styles = PackedInt32Array()
		cell_styles.resize(cell_count)
		cell_styles.fill(-1)
		var mask: PackedFloat32Array = terrain.get_meta(META_MASK, PackedFloat32Array())
		if mask.size() == resolution * resolution:
			for z in range(resolution - 1):
				for x in range(resolution - 1):
					if _cell_active_for_mask(mask, x, z, resolution):
						cell_styles[_cell_style_index(x, z, resolution)] = 0
		terrain.set_meta(META_CELL_STYLES, cell_styles)

func _cell_style_index(x: int, z: int, resolution: int) -> int:
	return z * (resolution - 1) + x

func _cell_style_at(terrain: Node3D, x: int, z: int) -> int:
	var resolution: int = terrain.get_meta(META_RESOLUTION)
	var cell_styles: PackedInt32Array = terrain.get_meta(META_CELL_STYLES)
	var index := _cell_style_index(x, z, resolution)
	if index < 0 or index >= cell_styles.size():
		return 0
	return max(cell_styles[index], 0)

func _cell_active_for_mask(mask: PackedFloat32Array, x: int, z: int, resolution: int) -> bool:
	if x < 0 or z < 0 or x >= resolution - 1 or z >= resolution - 1:
		return false
	var average := (
		mask[_grid_index(x, z, resolution)] +
		mask[_grid_index(x + 1, z, resolution)] +
		mask[_grid_index(x, z + 1, resolution)] +
		mask[_grid_index(x + 1, z + 1, resolution)]
	) * 0.25
	return average >= 0.5

func _assign_style_to_newly_active_cells(terrain: Node3D, old_mask: PackedFloat32Array, new_mask: PackedFloat32Array) -> void:
	_ensure_terrain_material_data(terrain)
	var resolution: int = terrain.get_meta(META_RESOLUTION)
	var cell_styles: PackedInt32Array = terrain.get_meta(META_CELL_STYLES)
	var selected_style_id := -1

	for z in range(resolution - 1):
		for x in range(resolution - 1):
			if _cell_active_for_mask(old_mask, x, z, resolution):
				continue
			if not _cell_active_for_mask(new_mask, x, z, resolution):
				continue
			if selected_style_id < 0:
				selected_style_id = _capture_current_paint_style(terrain)
			cell_styles[_cell_style_index(x, z, resolution)] = selected_style_id

	terrain.set_meta(META_CELL_STYLES, cell_styles)

func _assign_style_to_newly_active_cell_flags(terrain: Node3D, old_active: PackedByteArray, target_pos: Vector2, brush_radius: float) -> void:
	_ensure_terrain_material_data(terrain)

	var resolution: int = int(terrain.get_meta(META_RESOLUTION, DEFAULT_RESOLUTION))
	var world_size: float = float(terrain.get_meta(META_WORLD_SIZE, DEFAULT_WORLD_SIZE))
	var new_active: PackedByteArray = terrain.get_meta(META_CELL_ACTIVE, PackedByteArray())
	var cell_styles: PackedInt32Array = terrain.get_meta(META_CELL_STYLES, PackedInt32Array())
	var expected_size: int = (resolution - 1) * (resolution - 1)

	if new_active.size() != expected_size or cell_styles.size() != expected_size:
		return

	var spacing: float = world_size / float(resolution - 1)
	var influence: float = brush_radius + spacing * 1.5
	var selected_style_id := -1

	for z in range(resolution - 1):
		for x in range(resolution - 1):
			var index: int = _cell_style_index(x, z, resolution)
			if new_active[index] == 0:
				continue

			var a := _grid_to_local(x, z, resolution, world_size)
			var b := _grid_to_local(x + 1, z + 1, resolution, world_size)
			var center := Vector2((a.x + b.x) * 0.5, (a.z + b.z) * 0.5)
			if center.distance_to(target_pos) > influence:
				continue

			var was_active: bool = index < old_active.size() and old_active[index] != 0
			# Existing painted cells retain their material. Newly activated cells, and
			# legacy/missing-style cells at an expansion seam, receive the CURRENT
			# Paint Material including its textures and tile sizes.
			if was_active and cell_styles[index] >= 0:
				continue

			if selected_style_id < 0:
				selected_style_id = _capture_current_paint_style(terrain)
			cell_styles[index] = selected_style_id

	terrain.set_meta(META_CELL_STYLES, cell_styles)

func _capture_current_paint_style(terrain: Node3D) -> int:
	return _capture_style_definition(
		terrain,
		terrain.get_meta(META_BRUSH_TOP_COLOR, Color(0.44, 0.69, 0.20)),
		terrain.get_meta(META_BRUSH_CLIFF_COLOR, Color(0.45, 0.25, 0.13)),
		_get_optional_meta(terrain, META_BRUSH_TOP_TEXTURE) as Texture2D,
		_get_optional_meta(terrain, META_BRUSH_CLIFF_TEXTURE) as Texture2D,
		maxf(float(terrain.get_meta(META_BRUSH_TOP_TILE_SIZE, 4.0)), 0.001),
		maxf(float(terrain.get_meta(META_BRUSH_CLIFF_TILE_SIZE, 4.0)), 0.001)
	)

func _capture_style_definition(
	terrain: Node3D,
	top_color: Color,
	cliff_color: Color,
	top_texture: Texture2D,
	cliff_texture: Texture2D,
	top_tile_size: float,
	cliff_tile_size: float
) -> int:
	var signature := _paint_style_signature(top_color, cliff_color, top_texture, cliff_texture, top_tile_size, cliff_tile_size)
	var palette: Array = terrain.get_meta(META_STYLE_PALETTE, [])

	for i in range(palette.size()):
		var existing: Dictionary = palette[i]
		if String(existing.get("signature", "")) == signature:
			return i

	var style := {
		"top_color": top_color,
		"cliff_color": cliff_color,
		"top_texture": top_texture,
		"cliff_texture": cliff_texture,
		"top_tile_size": top_tile_size,
		"cliff_tile_size": cliff_tile_size,
		"signature": signature,
	}
	palette.append(style)
	terrain.set_meta(META_STYLE_PALETTE, palette)
	return palette.size() - 1

func _paint_style_signature(top_color: Color, cliff_color: Color, top_texture: Texture2D, cliff_texture: Texture2D, top_tile_size: float, cliff_tile_size: float) -> String:
	return "%s|%s|%s|%s|%.4f|%.4f" % [
		top_color.to_html(true),
		cliff_color.to_html(true),
		_resource_identity(top_texture),
		_resource_identity(cliff_texture),
		top_tile_size,
		cliff_tile_size,
	]

func _resource_identity(resource: Resource) -> String:
	if resource == null:
		return "none"
	if not resource.resource_path.is_empty():
		return resource.resource_path
	return "instance:%s" % resource.get_instance_id()

func _resource_path_or_empty(resource: Resource) -> String:
	if resource == null:
		return ""
	return resource.resource_path

func _migrate_style_texture_fields(style: Dictionary) -> Dictionary:
	# Compatibility with the previous build, which stored whole Materials. If a
	# StandardMaterial3D had an albedo texture, preserve that texture automatically.
	if not style.has("top_texture"):
		var old_top := style.get("top_material", null) as BaseMaterial3D
		style["top_texture"] = old_top.albedo_texture if old_top else null
	if not style.has("cliff_texture"):
		var old_cliff := style.get("cliff_material", null) as BaseMaterial3D
		style["cliff_texture"] = old_cliff.albedo_texture if old_cliff else null
	if not style.has("top_tile_size"):
		style["top_tile_size"] = 4.0
	if not style.has("cliff_tile_size"):
		style["cliff_tile_size"] = 4.0
	style.erase("top_material")
	style.erase("cliff_material")
	style["signature"] = _paint_style_signature(
		style.get("top_color", Color(0.44, 0.69, 0.20)),
		style.get("cliff_color", Color(0.45, 0.25, 0.13)),
		style.get("top_texture", null) as Texture2D,
		style.get("cliff_texture", null) as Texture2D,
		float(style.get("top_tile_size", 4.0)),
		float(style.get("cliff_tile_size", 4.0))
	)
	return style

func _get_style_geometry_group(groups: Dictionary, style_id: int) -> Dictionary:
	if not groups.has(style_id):
		groups[style_id] = {"vertices": [], "normals": []}
	return groups[style_id]

func _material_for_style(terrain: Node3D, style_id: int, top: bool) -> Material:
	var palette: Array = terrain.get_meta(META_STYLE_PALETTE, [_make_default_style()])
	if palette.is_empty():
		palette = [_make_default_style()]
	style_id = clamp(style_id, 0, palette.size() - 1)
	var style: Dictionary = _migrate_style_texture_fields(palette[style_id])
	var color_key := "top_color" if top else "cliff_color"
	var texture_key := "top_texture" if top else "cliff_texture"
	var texture := style.get(texture_key, null) as Texture2D

	var material := StandardMaterial3D.new()
	material.resource_name = "Terrain Top %d" % style_id if top else "Terrain Side %d" % style_id
	# A texture is treated as the complete albedo by default, so it is not
	# accidentally multiplied by the old grass/brown fallback color.
	material.albedo_color = Color.WHITE if texture else style.get(color_key, Color.WHITE)
	material.albedo_texture = texture
	material.texture_repeat = true
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED if bool(terrain.get_meta(META_DOUBLE_SIDED, false)) else BaseMaterial3D.CULL_BACK
	return material

func _tile_size_for_style(terrain: Node3D, style_id: int, top: bool) -> float:
	var palette: Array = terrain.get_meta(META_STYLE_PALETTE, [_make_default_style()])
	if palette.is_empty():
		return 4.0
	style_id = clamp(style_id, 0, palette.size() - 1)
	var style: Dictionary = _migrate_style_texture_fields(palette[style_id])
	return max(float(style.get("top_tile_size" if top else "cliff_tile_size", 4.0)), 0.001)

func _migrate_feature_style(feature_variant: Variant, feature_type: String) -> Dictionary:
	var feature: Dictionary = feature_variant.duplicate(true) if typeof(feature_variant) == TYPE_DICTIONARY else {}
	if feature_type == "road":
		if not feature.has("width"): feature["width"] = ROAD_WIDTH
		if not feature.has("y_offset"): feature["y_offset"] = 0.035
		if not feature.has("color"): feature["color"] = Color(0.76, 0.56, 0.31)
		if not feature.has("texture"): feature["texture"] = null
		if not feature.has("tile_size"): feature["tile_size"] = 4.0
		if not feature.has("collision"): feature["collision"] = true
	else:
		if not feature.has("width"): feature["width"] = RIVER_WIDTH
		if not feature.has("depth"): feature["depth"] = RIVER_DEPTH
		if not feature.has("surface_drop"): feature["surface_drop"] = 0.15
		if not feature.has("color"): feature["color"] = Color(0.12, 0.38, 0.55, 0.72)
		if not feature.has("texture"): feature["texture"] = null
		if not feature.has("normal_texture"): feature["normal_texture"] = null
		if not feature.has("tile_size"): feature["tile_size"] = 6.0
		if not feature.has("roughness"): feature["roughness"] = 0.18
		if not feature.has("normal_strength"): feature["normal_strength"] = 0.8
		if not feature.has("refraction"): feature["refraction"] = 0.012
		if not feature.has("flow_speed"): feature["flow_speed"] = 0.03
		if not feature.has("flow_angle"): feature["flow_angle"] = 32.211
		if not feature.has("collision"): feature["collision"] = false
	return feature

func _road_material_for_feature(terrain: Node3D, feature_variant: Variant) -> Material:
	var feature := _migrate_feature_style(feature_variant, "road")
	var texture := feature.get("texture", null) as Texture2D
	var material := StandardMaterial3D.new()
	material.resource_name = "LowPoly Road"
	material.albedo_color = Color.WHITE if texture else feature.get("color", Color(0.76, 0.56, 0.31))
	material.albedo_texture = texture
	material.texture_repeat = true
	material.roughness = 1.0
	material.cull_mode = BaseMaterial3D.CULL_DISABLED if bool(terrain.get_meta(META_DOUBLE_SIDED, false)) else BaseMaterial3D.CULL_BACK
	return material

func _get_generated_water_normal() -> Texture2D:
	if is_instance_valid(_generated_water_normal):
		return _generated_water_normal
	# Build the same kind of seamless procedural normal resource a user would
	# normally create by hand in the Inspector: NoiseTexture2D + FastNoiseLite,
	# converted to a normal map. A custom Water Normal Texture still overrides it.
	var noise := FastNoiseLite.new()
	noise.frequency = 0.035
	noise.fractal_octaves = 4
	var texture := NoiseTexture2D.new()
	texture.width = 256
	texture.height = 256
	texture.seamless = true
	texture.as_normal_map = true
	texture.noise = noise
	_generated_water_normal = texture
	return _generated_water_normal

func _river_material_for_feature(feature_variant: Variant) -> Material:
	var feature := _migrate_feature_style(feature_variant, "river")
	var shader := Shader.new()
	shader.code = """
shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

uniform vec4 water_color : source_color = vec4(0.12, 0.38, 0.55, 0.72);
uniform sampler2D albedo_texture : source_color, filter_linear_mipmap, repeat_enable;
uniform bool use_albedo_texture = false;
uniform sampler2D normal_texture : hint_normal, filter_linear_mipmap, repeat_enable;
uniform bool use_normal_texture = false;
uniform sampler2D screen_texture : hint_screen_texture, filter_linear_mipmap;
uniform float tile_scale = 0.1666667;
uniform float flow_speed = 0.03;
uniform vec2 flow_direction = vec2(0.845, 0.533);
uniform float roughness_value : hint_range(0.0, 1.0) = 0.18;
uniform float normal_strength : hint_range(0.0, 4.0) = 0.8;
uniform float refraction_strength : hint_range(0.0, 0.08) = 0.012;
varying vec3 world_position;

void vertex() {
	world_position = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	vec2 flow = flow_direction * (TIME * flow_speed);
	vec2 water_uv = world_position.xz * tile_scale + flow;
	vec4 albedo_sample = vec4(1.0);
	if (use_albedo_texture) {
		albedo_sample = texture(albedo_texture, water_uv);
	}
	vec3 normal_sample = vec3(0.5, 0.5, 1.0);
	if (use_normal_texture) {
		normal_sample = texture(normal_texture, water_uv).rgb;
		NORMAL_MAP = normal_sample;
		NORMAL_MAP_DEPTH = normal_strength;
	}
	ALBEDO = water_color.rgb * albedo_sample.rgb;
	ROUGHNESS = roughness_value;
	SPECULAR = 0.85;
	float alpha_value = clamp(water_color.a * albedo_sample.a, 0.0, 1.0);
	if (refraction_strength > 0.0) {
		vec2 normal_offset = (normal_sample.rg * 2.0 - 1.0) * refraction_strength;
		vec3 refracted = textureLod(screen_texture, SCREEN_UV + normal_offset, roughness_value * 4.0).rgb;
		EMISSION += refracted * (1.0 - alpha_value) * 0.65;
	}
	ALPHA = alpha_value;
}
"""
	var material := ShaderMaterial.new()
	material.resource_name = "LowPoly River Water"
	material.shader = shader
	var color: Color = feature.get("color", Color(0.12, 0.38, 0.55, 0.72))
	var texture := feature.get("texture", null) as Texture2D
	var normal_texture := feature.get("normal_texture", null) as Texture2D
	if normal_texture == null:
		normal_texture = _get_generated_water_normal()
	var tile_size: float = maxf(float(feature.get("tile_size", 6.0)), 0.001)
	material.set_shader_parameter("water_color", color)
	material.set_shader_parameter("use_albedo_texture", texture != null)
	if texture != null:
		material.set_shader_parameter("albedo_texture", texture)
	material.set_shader_parameter("use_normal_texture", normal_texture != null)
	if normal_texture != null:
		material.set_shader_parameter("normal_texture", normal_texture)
	material.set_shader_parameter("tile_scale", 1.0 / tile_size)
	material.set_shader_parameter("flow_speed", float(feature.get("flow_speed", 0.03)))
	var flow_angle_degrees: float = float(feature.get("flow_angle", 32.211))
	var flow_angle_radians := deg_to_rad(flow_angle_degrees)
	material.set_shader_parameter("flow_direction", Vector2(cos(flow_angle_radians), sin(flow_angle_radians)))
	material.set_shader_parameter("roughness_value", clampf(float(feature.get("roughness", 0.18)), 0.0, 1.0))
	material.set_shader_parameter("normal_strength", maxf(float(feature.get("normal_strength", 0.8)), 0.0))
	material.set_shader_parameter("refraction_strength", maxf(float(feature.get("refraction", 0.012)), 0.0))
	return material

func _update_terrain_collision(terrain: Node3D, top_groups: Dictionary, cliff_groups: Dictionary, feature_faces: PackedVector3Array = PackedVector3Array()) -> void:
	var enabled: bool = terrain.get_meta(META_COLLISION_ENABLED, false)
	var body := terrain.get_node_or_null(GENERATED_COLLISION_BODY_NAME) as StaticBody3D

	if not enabled:
		if body:
			var existing_shape := body.get_node_or_null(GENERATED_COLLISION_SHAPE_NAME) as CollisionShape3D
			if existing_shape:
				existing_shape.disabled = true
		return

	var scene_root := get_editor_interface().get_edited_scene_root()
	if not body:
		body = StaticBody3D.new()
		body.name = GENERATED_COLLISION_BODY_NAME
		terrain.add_child(body)
		if scene_root:
			body.owner = scene_root

	var collision_shape := body.get_node_or_null(GENERATED_COLLISION_SHAPE_NAME) as CollisionShape3D
	if not collision_shape:
		collision_shape = CollisionShape3D.new()
		collision_shape.name = GENERATED_COLLISION_SHAPE_NAME
		body.add_child(collision_shape)
		if scene_root:
			collision_shape.owner = scene_root

	var layer_number := clamp(int(terrain.get_meta(META_COLLISION_LAYER, 1)), 1, 32)
	body.collision_layer = 1 << (layer_number - 1)
	body.collision_mask = 0

	var faces := PackedVector3Array()
	for top_group_variant in top_groups.values():
		var top_collision_group: Dictionary = top_group_variant
		faces.append_array(PackedVector3Array(top_collision_group["vertices"]))
	for cliff_group_variant in cliff_groups.values():
		var cliff_collision_group: Dictionary = cliff_group_variant
		faces.append_array(PackedVector3Array(cliff_collision_group["vertices"]))
	if not feature_faces.is_empty():
		faces.append_array(feature_faces)

	if faces.is_empty():
		collision_shape.shape = null
		collision_shape.disabled = true
		return

	var concave := ConcavePolygonShape3D.new()
	concave.backface_collision = true
	concave.set_faces(faces)
	collision_shape.shape = concave
	collision_shape.disabled = false

func _color_to_array(color: Color) -> Array:
	return [color.r, color.g, color.b, color.a]

func _serialize_style_palette(palette: Array) -> Array:
	var output: Array = []
	for style_variant in palette:
		var style: Dictionary = _migrate_style_texture_fields(style_variant)
		var top_texture := style.get("top_texture", null) as Texture2D
		var cliff_texture := style.get("cliff_texture", null) as Texture2D
		output.append({
			"top_color": _color_to_array(style.get("top_color", Color.WHITE)),
			"cliff_color": _color_to_array(style.get("cliff_color", Color.WHITE)),
			"top_texture_path": _resource_path_or_empty(top_texture),
			"cliff_texture_path": _resource_path_or_empty(cliff_texture),
			"top_tile_size": float(style.get("top_tile_size", 4.0)),
			"cliff_tile_size": float(style.get("cliff_tile_size", 4.0)),
			"signature": style.get("signature", ""),
		})
	return output

# =============================================================================
# MATERIALS
# =============================================================================

func _create_materials() -> void:
	_top_material = StandardMaterial3D.new()
	_top_material.resource_name = "Terrain Grass"
	_top_material.albedo_color = Color(0.44, 0.69, 0.20)
	_top_material.roughness = 1.0
	_top_material.cull_mode = BaseMaterial3D.CULL_BACK

	_cliff_material = StandardMaterial3D.new()
	_cliff_material.resource_name = "Terrain Cliff"
	_cliff_material.albedo_color = Color(0.45, 0.25, 0.13)
	_cliff_material.roughness = 1.0
	_cliff_material.cull_mode = BaseMaterial3D.CULL_BACK

	_road_material = StandardMaterial3D.new()
	_road_material.resource_name = "Terrain Road"
	_road_material.albedo_color = Color(0.76, 0.56, 0.31)
	_road_material.roughness = 1.0
	_road_material.cull_mode = BaseMaterial3D.CULL_BACK

	_river_material = StandardMaterial3D.new()
	_river_material.resource_name = "River Bed"
	_river_material.albedo_color = Color(0.28, 0.32, 0.25)
	_river_material.roughness = 1.0
	_river_material.cull_mode = BaseMaterial3D.CULL_BACK

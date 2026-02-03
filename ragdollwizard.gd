@tool
extends EditorPlugin

# Ragdoll standards and knowledge base
const RAGDOLL_STANDARDS = {
	"collision_min_radius": 0.02,  # 2cm minimum for stable physics
	"joint_types": {
		"elbow": {"type": "HINGE", "min": 0.0, "max": 150.0},
		"knee": {"type": "HINGE", "min": 0.0, "max": 150.0},
		"shoulder": {"type": "CONE_TWIST", "swing": 90.0, "twist": 45.0},
		"hip": {"type": "CONE_TWIST", "swing": 45.0, "twist": 30.0},
	},
	"guidance": {
		"fingers": "Fingers usually don't need physics - they add complexity and performance cost without benefit",
		"collision_size": "Small collision shapes (< 2cm) cause physics instability and tunneling through objects",
		"pin_joints": "Pin joints allow 360° rotation - use specific joint types for realistic motion",
	}
}

const BONE_PATTERNS = {
	"hips": ["hips", "pelvis"],
	"spine": ["spine.001", "spine1"],
	"chest": ["spine.003", "spine3"],
	"neck": ["neck"],
	"head": ["head"],
	"upper_arm_l": ["upper_arm.l", "upperarm.l"],
	"forearm_l": ["forearm.l"],
	"hand_l": ["hand.l"],
	"upper_arm_r": ["upper_arm.r", "upperarm.r"],
	"forearm_r": ["forearm.r"],
	"hand_r": ["hand.r"],
	"thigh_l": ["thigh.l"],
	"shin_l": ["shin.l"],
	"foot_l": ["foot.l"],
	"thigh_r": ["thigh.r"],
	"shin_r": ["shin.r"],
	"foot_r": ["foot.r"],
}

var dock: Control
var issue_list: VBoxContainer
var standards_panel: RichTextLabel
var status_label: Label
var current_issues = []
var fixed_issues = {}  # Maps issue -> original values for restore
var current_simulator: PhysicalBoneSimulator3D = null

func _enter_tree():
	dock = Control.new()
	dock.name = "RagdollWizard"
	
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 5)
	dock.add_child(vbox)
	
	# Header
	var title = Label.new()
	title.text = "RagdollWizard - Diagnostic"
	title.add_theme_font_size_override("font_size", 14)
	vbox.add_child(title)
	
	# Action buttons
	var hbox_buttons = HBoxContainer.new()
	hbox_buttons.add_theme_constant_override("separation", 5)
	vbox.add_child(hbox_buttons)
	
	var scan_btn = Button.new()
	scan_btn.text = "Scan Ragdoll"
	scan_btn.pressed.connect(_on_scan_pressed)
	hbox_buttons.add_child(scan_btn)
	
	var auto_btn = Button.new()
	auto_btn.text = "Auto-Resolve All"
	auto_btn.pressed.connect(_on_auto_resolve_pressed)
	hbox_buttons.add_child(auto_btn)
	
	vbox.add_child(HSeparator.new())
	
	# Issue list (scrollable)
	var scroll = ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 300)
	vbox.add_child(scroll)
	
	issue_list = VBoxContainer.new()
	issue_list.add_theme_constant_override("separation", 3)
	scroll.add_child(issue_list)
	
	vbox.add_child(HSeparator.new())
	
	# Standards reference
	var standards_title = Label.new()
	standards_title.text = "Ragdoll Standards & Guidance"
	standards_title.add_theme_font_size_override("font_size", 12)
	vbox.add_child(standards_title)
	
	standards_panel = RichTextLabel.new()
	standards_panel.custom_minimum_size = Vector2(0, 150)
	standards_panel.bbcode_enabled = true
	standards_panel.fit_content = true
	standards_panel.scroll_active = false
	_update_standards_panel()
	vbox.add_child(standards_panel)
	
	vbox.add_child(HSeparator.new())
	
	# Status
	status_label = Label.new()
	status_label.text = "Select a ragdoll node and click 'Scan Ragdoll'"
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(status_label)
	
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)

func _exit_tree():
	remove_control_from_docks(dock)
	dock.queue_free()

func _update_standards_panel():
	standards_panel.text = """[b]Collision Shapes:[/b]
• Minimum radius: 2cm (prevents instability)
• Smaller shapes = jittering, tunneling

[b]Joint Types:[/b]
• Elbows/Knees: HINGE (0-150°)
• Shoulders/Hips: CONE_TWIST
• Avoid PIN joints (unrealistic spinning)

[b]Performance Tips:[/b]
• Fingers: Usually skip physics
• Focus on main limbs for ragdoll
• More bones = slower physics

[b]Why These Matter:[/b]
Physics engines need stable shapes and realistic constraints to work properly."""

func _on_scan_pressed():
	# Clear previous issues
	for child in issue_list.get_children():
		child.queue_free()
	current_issues.clear()
	
	# Find PhysicalBoneSimulator3D in the scene
	var edited_scene = get_editor_interface().get_edited_scene_root()
	if not edited_scene:
		status_label.text = "❌ No scene opened"
		return
	
	current_simulator = _find_simulator(edited_scene)
	if not current_simulator:
		status_label.text = "❌ No PhysicalBoneSimulator3D found in scene"
		return
	
	# Auto-select the simulator
	get_editor_interface().get_selection().clear()
	get_editor_interface().get_selection().add_node(current_simulator)
	get_editor_interface().edit_node(current_simulator)
	
	# Enable debug view (collision shapes visible)
	_enable_debug_view()
	
	status_label.text = "🔍 Scanning %s..." % current_simulator.name
	
	# Detect issues
	_detect_all_issues()
	
	# Display issues
	_display_issues()
	
	status_label.text = "✅ Scan complete: %d issues found" % current_issues.size()

func _detect_all_issues():
	if not current_simulator:
		return
	
	for bone_node in current_simulator.get_children():
		if not bone_node is PhysicalBone3D:
			continue
		
		# Check collision shape size
		for child in bone_node.get_children():
			if child is CollisionShape3D and child.shape is CapsuleShape3D:
				if child.shape.radius < RAGDOLL_STANDARDS.collision_min_radius:
					current_issues.append({
						"type": "collision_small",
						"bone": bone_node,
						"current_value": child.shape.radius,
						"recommended": RAGDOLL_STANDARDS.collision_min_radius,
						"shape": child.shape
					})
		
		# Check joint type
		var bone_type = _identify_bone_type(bone_node)
		if bone_type in ["forearm_l", "forearm_r", "shin_l", "shin_r"]:
			if bone_node.joint_type != PhysicalBone3D.JOINT_TYPE_HINGE:
				current_issues.append({
					"type": "joint_wrong",
					"bone": bone_node,
					"current_type": _joint_type_name(bone_node.joint_type),
					"recommended_type": "HINGE",
					"bone_type": bone_type
				})
		elif bone_type in ["upper_arm_l", "upper_arm_r", "thigh_l", "thigh_r"]:
			if bone_node.joint_type != PhysicalBone3D.JOINT_TYPE_CONE:
				current_issues.append({
					"type": "joint_wrong",
					"bone": bone_node,
					"current_type": _joint_type_name(bone_node.joint_type),
					"recommended_type": "CONE_TWIST",
					"bone_type": bone_type
				})

func _display_issues():
	# Group issues by type
	var collision_issues = current_issues.filter(func(i): return i.type == "collision_small")
	var joint_issues = current_issues.filter(func(i): return i.type == "joint_wrong")
	
	if collision_issues.size() > 0:
		var header = Label.new()
		header.text = "⚠ Collision Shape Issues (%d)" % collision_issues.size()
		header.add_theme_color_override("font_color", Color(1.0, 0.6, 0.0))
		issue_list.add_child(header)
		
		for issue in collision_issues.slice(0, 5):  # Show first 5
			_create_issue_item(issue)
		
		if collision_issues.size() > 5:
			var more = Label.new()
			more.text = "   ... and %d more" % (collision_issues.size() - 5)
			more.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			issue_list.add_child(more)
	
	if joint_issues.size() > 0:
		issue_list.add_child(HSeparator.new())
		var header = Label.new()
		header.text = "⚠ Joint Type Issues (%d)" % joint_issues.size()
		header.add_theme_color_override("font_color", Color(1.0, 0.6, 0.0))
		issue_list.add_child(header)
		
		for issue in joint_issues.slice(0, 5):
			_create_issue_item(issue)
		
		if joint_issues.size() > 5:
			var more = Label.new()
			more.text = "   ... and %d more" % (joint_issues.size() - 5)
			more.add_theme_color_override("font_color", Color(0.5, 0.5, 0.5))
			issue_list.add_child(more)

func _create_issue_item(issue: Dictionary):
	var item = VBoxContainer.new()
	item.add_theme_constant_override("separation", 2)
	
	# Check if this bone was already fixed
	var was_fixed = fixed_issues.has(issue.bone.bone_name)
	
	var header_box = HBoxContainer.new()
	header_box.add_theme_constant_override("separation", 5)
	
	var bone_label = Label.new()
	if was_fixed:
		bone_label.text = "✓ " + issue.bone.bone_name
		bone_label.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))  # Green for fixed
	else:
		bone_label.text = "• " + issue.bone.bone_name
		bone_label.add_theme_color_override("font_color", Color(0.8, 0.8, 1.0))
	header_box.add_child(bone_label)
	
	var select_btn = Button.new()
	select_btn.text = "Select"
	select_btn.custom_minimum_size = Vector2(60, 0)
	select_btn.pressed.connect(func(): _select_bone(issue.bone))
	header_box.add_child(select_btn)
	
	var fix_btn = Button.new()
	if was_fixed:
		fix_btn.text = "Restore"
		fix_btn.modulate = Color(1.0, 0.8, 0.5)  # Orange tint for restore
		fix_btn.pressed.connect(func(): _restore_issue(issue))
	else:
		fix_btn.text = "Quick Fix"
		fix_btn.pressed.connect(func(): _quick_fix_issue(issue))
	fix_btn.custom_minimum_size = Vector2(80, 0)
	header_box.add_child(fix_btn)
	
	item.add_child(header_box)
	
	var detail = Label.new()
	if was_fixed:
		detail.text = "    ✓ Fixed"
		detail.add_theme_color_override("font_color", Color(0.4, 1.0, 0.4))
	elif issue.type == "collision_small":
		detail.text = "    Current: %.4fm  →  Standard: %.4fm" % [issue.current_value, issue.recommended]
	elif issue.type == "joint_wrong":
		detail.text = "    Current: %s  →  Standard: %s" % [issue.current_type, issue.recommended_type]
	detail.add_theme_color_override("font_color", Color(0.7, 0.7, 0.7) if not was_fixed else Color(0.4, 1.0, 0.4))
	detail.add_theme_font_size_override("font_size", 11)
	item.add_child(detail)
	
	issue_list.add_child(item)

func _select_bone(bone: PhysicalBone3D):
	# Select in editor
	get_editor_interface().get_selection().clear()
	get_editor_interface().get_selection().add_node(bone)
	get_editor_interface().edit_node(bone)
	
	# Focus camera on the selected bone - manual implementation
	# Get the bone's global position
	var bone_pos = bone.global_position
	
	# Calculate AABB for the bone (includes collision shapes)
	var aabb = AABB(bone_pos, Vector3.ZERO)
	for child in bone.get_children():
		if child is CollisionShape3D and child.shape:
			# Expand AABB to include collision shape
			if child.shape is CapsuleShape3D:
				var capsule = child.shape as CapsuleShape3D
				var size = Vector3(capsule.radius * 2, capsule.height, capsule.radius * 2)
				aabb = aabb.expand(bone_pos + size / 2)
				aabb = aabb.expand(bone_pos - size / 2)
	
	# Ensure AABB has minimum size
	if aabb.size.length() < 0.1:
		aabb = aabb.grow(0.5)
	
	# Get the active 3D viewport and its camera
	var viewport = get_editor_interface().get_editor_viewport_3d(0)
	if viewport:
		for child in viewport.get_children():
			if child is Camera3D:
				var camera = child as Camera3D
				
				# Calculate camera distance based on AABB size and FOV
				var aabb_size = aabb.size.length()
				var fov_rad = deg_to_rad(camera.fov)
				var distance = (aabb_size / 2.0) / tan(fov_rad / 2.0) * 1.5  # 1.5 = padding factor
				
				# Position camera to look at bone from current camera direction
				var camera_dir = -camera.global_transform.basis.z
				var target_pos = aabb.get_center() - camera_dir * distance
				
				# Smoothly move camera (or instant if you prefer)
				camera.global_position = target_pos
				camera.look_at(aabb.get_center(), Vector3.UP)
				
				break
	
	status_label.text = "Focused: %s" % bone.bone_name

func _quick_fix_issue(issue: Dictionary):
	# Store original values for restore
	var backup = {}
	
	if issue.type == "collision_small":
		var shape = issue.shape as CapsuleShape3D
		backup = {
			"type": "collision_small",
			"bone": issue.bone,
			"shape": shape,
			"radius": shape.radius,
			"height": shape.height
		}
		var scale_factor = RAGDOLL_STANDARDS.collision_min_radius / shape.radius
		shape.radius = RAGDOLL_STANDARDS.collision_min_radius
		shape.height = max(shape.height * scale_factor, RAGDOLL_STANDARDS.collision_min_radius * 2)
		status_label.text = "✓ Fixed: %s collision shape" % issue.bone.bone_name
	
	elif issue.type == "joint_wrong":
		backup = {
			"type": "joint_wrong",
			"bone": issue.bone,
			"joint_type": issue.bone.joint_type,
			"bone_type": issue.get("bone_type", "")
		}
		if issue.recommended_type == "HINGE":
			issue.bone.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
			issue.bone.set("joint_constraints/angular_limit_enabled", true)
			issue.bone.set("joint_constraints/angular_limit_lower", 0.0)
			issue.bone.set("joint_constraints/angular_limit_upper", deg_to_rad(150))
		elif issue.recommended_type == "CONE_TWIST":
			issue.bone.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
			issue.bone.set("joint_constraints/swing_span", deg_to_rad(90))
			issue.bone.set("joint_constraints/twist_span", deg_to_rad(45))
		status_label.text = "✓ Fixed: %s joint type" % issue.bone.bone_name
	
	# Store backup for restore
	fixed_issues[issue.bone.bone_name] = backup
	
	# Rebuild display to show "✓" and "Restore" button
	for child in issue_list.get_children():
		child.queue_free()
	_display_issues()
	
	# Update status
	var unfixed_count = current_issues.size() - fixed_issues.size()
	if unfixed_count == 0:
		status_label.text = "✓ All issues fixed!"
	else:
		status_label.text = "✓ Fixed - %d unfixed remaining" % unfixed_count

func _restore_issue(issue: Dictionary):
	var bone_name = issue.bone.bone_name
	if not fixed_issues.has(bone_name):
		return
	
	var backup = fixed_issues[bone_name]
	
	# Restore original values
	if backup.type == "collision_small":
		backup.shape.radius = backup.radius
		backup.shape.height = backup.height
		status_label.text = "↶ Restored: %s collision shape" % bone_name
	elif backup.type == "joint_wrong":
		backup.bone.joint_type = backup.joint_type
		status_label.text = "↶ Restored: %s joint type" % bone_name
	
	# Remove from fixed list
	fixed_issues.erase(bone_name)
	
	# Rebuild display to show "Quick Fix" button again
	for child in issue_list.get_children():
		child.queue_free()
	_display_issues()
	
	# Update status
	var unfixed_count = current_issues.size() - fixed_issues.size()
	status_label.text = "↶ Restored - %d unfixed remaining" % unfixed_count

func _on_auto_resolve_pressed():
	if current_issues.size() == 0:
		status_label.text = "No issues to fix - run Scan first"
		return
	
	var fixed_count = 0
	for issue in current_issues:
		_quick_fix_issue(issue)
		fixed_count += 1
	
	status_label.text = "✓ Auto-resolved %d issues" % fixed_count
	_on_scan_pressed()

func _identify_bone_type(bone: PhysicalBone3D) -> String:
	var bone_name = bone.bone_name.to_lower().replace("def-", "").replace("_", "").replace(".", "")
	for key in BONE_PATTERNS:
		for pattern in BONE_PATTERNS[key]:
			var clean_pattern = pattern.replace(".", "").replace("_", "")
			if clean_pattern in bone_name:
				return key
	return ""

func _joint_type_name(type: int) -> String:
	match type:
		0: return "NONE"
		1: return "PIN"
		2: return "CONE"
		3: return "HINGE"
		4: return "SLIDER"
		5: return "6DOF"
		_: return "UNKNOWN"

func _find_simulator(node: Node) -> PhysicalBoneSimulator3D:
	if node is PhysicalBoneSimulator3D:
		return node
	for child in node.get_children():
		if child is PhysicalBone3D:
			continue
		var result = _find_simulator(child)
		if result:
			return result
	return null

func _enable_debug_view():
	# Enable collision shapes visibility using SceneTree debug hint
	var tree = get_editor_interface().get_edited_scene_root().get_tree()
	if tree:
		tree.debug_collisions_hint = true
		print("RagdollWizard: Enabled collision shapes")
	
	# Set viewport to overdraw mode - the viewport returned IS already a SubViewport!
	print("RagdollWizard: Enabling overdraw mode...")
	var viewport = get_editor_interface().get_editor_viewport_3d(0)
	if viewport and viewport is SubViewport:
		viewport.debug_draw = SubViewport.DEBUG_DRAW_OVERDRAW
		print("RagdollWizard: ✓ Overdraw mode enabled on viewport 0")
		status_label.text = "✓ Collision shapes + overdraw enabled"
	else:
		print("RagdollWizard: ✗ Failed to enable overdraw (viewport not found)")
		status_label.text = "✓ Collision shapes enabled"




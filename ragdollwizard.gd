@tool
extends EditorPlugin

const BONE_PATTERNS = {
	"hips": ["hips", "pelvis", "root"],
	"spine": ["spine"],
	"chest": ["chest", "spine.003", "spine_03"],
	"neck": ["neck"],
	"head": ["head"],
	
	"upper_arm_l": ["upper_arm.l", "upperarm_l", "leftarm", "arm_l", "shoulder.l"],
	"forearm_l": ["forearm.l", "lowerarm_l", "leftforearm"],
	"hand_l": ["hand.l", "lefthand"],
	
	"upper_arm_r": ["upper_arm.r", "upperarm_r", "rightarm", "arm_r", "shoulder.r"],
	"forearm_r": ["forearm.r", "lowerarm_r", "rightforearm"],
	"hand_r": ["hand.r", "righthand"],
	
	"thigh_l": ["thigh.l", "upleg_l", "leftupleg", "leg_l"],
	"shin_l": ["shin.l", "calf.l", "lowleg_l", "leftleg"],
	"foot_l": ["foot.l", "leftfoot"],
	
	"thigh_r": ["thigh.r", "upleg_r", "rightupleg", "leg_r"],
	"shin_r": ["shin.r", "calf.r", "lowleg_r", "rightleg"],
	"foot_r": ["foot.r", "rightfoot"],
}

var dock: Control
var selected_skeleton: Skeleton3D = null

func _enter_tree():
	# Create dock UI
	dock = Control.new()
	dock.name = "RagdollWizard"
	
	var vbox = VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	dock.add_child(vbox)
	
	# Title
	var title = Label.new()
	title.text = "RagdollWizard"
	title.add_theme_font_size_override("font_size", 16)
	vbox.add_child(title)
	
	vbox.add_child(HSeparator.new())
	
	# Instructions
	var instructions = Label.new()
	instructions.text = "1. Select a node with PhysicalBoneSimulator3D\n2. Click 'Configure Ragdoll'"
	instructions.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(instructions)
	
	vbox.add_child(HSeparator.new())
	
	# Configure button
	var configure_btn = Button.new()
	configure_btn.text = "Configure Humanoid Ragdoll"
	configure_btn.pressed.connect(_on_configure_pressed)
	vbox.add_child(configure_btn)
	
	# Health check button
	var health_btn = Button.new()
	health_btn.text = "Run Health Check"
	health_btn.pressed.connect(_on_health_check_pressed)
	vbox.add_child(health_btn)
	
	vbox.add_child(HSeparator.new())
	
	# Status label
	var status = Label.new()
	status.name = "StatusLabel"
	status.text = "Ready"
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(status)
	
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)

func _exit_tree():
	remove_control_from_docks(dock)
	dock.queue_free()

func _on_configure_pressed():
	var selection = get_editor_interface().get_selection().get_selected_nodes()
	if selection.size() == 0:
		_set_status("❌ No node selected", Color.RED)
		return
	
	var simulator = _find_physical_bone_simulator(selection[0])
	if not simulator:
		_set_status("❌ No PhysicalBoneSimulator3D found in selection", Color.RED)
		return
	
	var skeleton = simulator.get_parent()
	if not skeleton is Skeleton3D:
		_set_status("❌ PhysicalBoneSimulator3D must be child of Skeleton3D", Color.RED)
		return
	
	_set_status("🔍 Detecting humanoid bones...", Color.YELLOW)
	await get_tree().process_frame
	
	var bone_map = _detect_bones(simulator)
	_set_status("✅ Found %d/%d key bones" % [bone_map.size(), BONE_PATTERNS.size()], Color.GREEN)
	
	_apply_humanoid_configuration(simulator, bone_map)
	_set_status("✅ Ragdoll configured successfully!", Color.GREEN)

func _on_health_check_pressed():
	var selection = get_editor_interface().get_selection().get_selected_nodes()
	if selection.size() == 0:
		_set_status("❌ No node selected", Color.RED)
		return
	
	var simulator = _find_physical_bone_simulator(selection[0])
	if not simulator:
		_set_status("❌ No PhysicalBoneSimulator3D found", Color.RED)
		return
	
	var issues = _run_health_check(simulator)
	if issues.size() == 0:
		_set_status("✅ No issues found!", Color.GREEN)
	else:
		_set_status("⚠️ Found %d issues:\n%s" % [issues.size(), "\n".join(issues)], Color.ORANGE)

func _find_physical_bone_simulator(node: Node) -> PhysicalBoneSimulator3D:
	if node is PhysicalBoneSimulator3D:
		return node
	
	for child in node.get_children():
		if child is PhysicalBoneSimulator3D:
			return child
		var result = _find_physical_bone_simulator(child)
		if result:
			return result
	
	return null

func _detect_bones(simulator: PhysicalBoneSimulator3D) -> Dictionary:
	var bone_map = {}
	
	for bone_node in simulator.get_children():
		if not bone_node is PhysicalBone3D:
			continue
		
		var bone_name = bone_node.bone_name.to_lower()
		# Remove common prefixes
		bone_name = bone_name.replace("def-", "").replace("mixamorig:", "").replace("_", "")
		
		for key in BONE_PATTERNS:
			for pattern in BONE_PATTERNS[key]:
				var clean_pattern = pattern.replace(".", "").replace("_", "")
				if clean_pattern in bone_name or bone_name in clean_pattern:
					bone_map[key] = bone_node
					break
	
	return bone_map

func _apply_humanoid_configuration(simulator: PhysicalBoneSimulator3D, bone_map: Dictionary):
	# Apply joint types and constraints
	_configure_hinge_joint(bone_map.get("forearm_l"), deg_to_rad(0), deg_to_rad(150))
	_configure_hinge_joint(bone_map.get("forearm_r"), deg_to_rad(0), deg_to_rad(150))
	_configure_hinge_joint(bone_map.get("shin_l"), deg_to_rad(0), deg_to_rad(150))
	_configure_hinge_joint(bone_map.get("shin_r"), deg_to_rad(0), deg_to_rad(150))
	
	# Cone-twist for shoulders and hips
	_configure_cone_twist(bone_map.get("upper_arm_l"), deg_to_rad(90), deg_to_rad(45))
	_configure_cone_twist(bone_map.get("upper_arm_r"), deg_to_rad(90), deg_to_rad(45))
	_configure_cone_twist(bone_map.get("thigh_l"), deg_to_rad(45), deg_to_rad(30))
	_configure_cone_twist(bone_map.get("thigh_r"), deg_to_rad(45), deg_to_rad(30))
	
	# Spine and neck slight movement
	_configure_limited_pin(bone_map.get("spine"), deg_to_rad(30))
	_configure_limited_pin(bone_map.get("chest"), deg_to_rad(20))
	_configure_cone_twist(bone_map.get("neck"), deg_to_rad(60), deg_to_rad(30))
	
	# Physics parameters
	_apply_physics_params(bone_map.get("hips"), 15.0, 0.2, 0.5)
	_apply_physics_params(bone_map.get("spine"), 10.0, 0.2, 0.5)
	_apply_physics_params(bone_map.get("chest"), 8.0, 0.2, 0.5)
	_apply_physics_params(bone_map.get("head"), 5.0, 0.3, 0.5)
	
	_apply_physics_params(bone_map.get("upper_arm_l"), 3.0, 0.3, 0.5)
	_apply_physics_params(bone_map.get("upper_arm_r"), 3.0, 0.3, 0.5)
	_apply_physics_params(bone_map.get("forearm_l"), 2.0, 0.3, 0.5)
	_apply_physics_params(bone_map.get("forearm_r"), 2.0, 0.3, 0.5)
	
	_apply_physics_params(bone_map.get("thigh_l"), 8.0, 0.2, 0.5)
	_apply_physics_params(bone_map.get("thigh_r"), 8.0, 0.2, 0.5)
	_apply_physics_params(bone_map.get("shin_l"), 5.0, 0.2, 0.5)
	_apply_physics_params(bone_map.get("shin_r"), 5.0, 0.2, 0.5)

func _configure_hinge_joint(bone: PhysicalBone3D, min_angle: float, max_angle: float):
	if not bone:
		return
	
	bone.joint_type = PhysicalBone3D.JOINT_TYPE_HINGE
	bone.set("joint_constraints/angular_limit_enabled", true)
	bone.set("joint_constraints/angular_limit_lower", min_angle)
	bone.set("joint_constraints/angular_limit_upper", max_angle)
	bone.set("joint_constraints/angular_spring_stiffness", 0.0)
	bone.set("joint_constraints/angular_spring_damping", 0.3)

func _configure_cone_twist(bone: PhysicalBone3D, swing_span: float, twist_span: float):
	if not bone:
		return
	
	bone.joint_type = PhysicalBone3D.JOINT_TYPE_CONE
	bone.set("joint_constraints/swing_span", swing_span)
	bone.set("joint_constraints/twist_span", twist_span)
	bone.set("joint_constraints/bias", 0.3)
	bone.set("joint_constraints/softness", 0.5)
	bone.set("joint_constraints/relaxation", 1.0)

func _configure_limited_pin(bone: PhysicalBone3D, limit: float):
	if not bone:
		return
	
	bone.joint_type = PhysicalBone3D.JOINT_TYPE_PIN
	bone.set("joint_constraints/bias", 0.3)
	bone.set("joint_constraints/damping", 0.5)

func _apply_physics_params(bone: PhysicalBone3D, mass: float, damping: float, softness: float):
	if not bone:
		return
	
	bone.mass = mass
	bone.linear_damp = damping
	bone.angular_damp = damping
	bone.set("joint_constraints/damping", damping)
	if bone.has("joint_constraints/softness"):
		bone.set("joint_constraints/softness", softness)

func _run_health_check(simulator: PhysicalBoneSimulator3D) -> Array:
	var issues = []
	
	for bone_node in simulator.get_children():
		if not bone_node is PhysicalBone3D:
			continue
		
		# Check for collision shape
		var has_collision = false
		for child in bone_node.get_children():
			if child is CollisionShape3D:
				has_collision = true
				# Check if shape is too small
				if child.shape is CapsuleShape3D:
					if child.shape.radius < 0.01:
						issues.append("⚠️ %s: Collision shape too small (r=%.4f)" % [bone_node.bone_name, child.shape.radius])
		
		if not has_collision:
			issues.append("❌ %s: Missing collision shape" % bone_node.bone_name)
		
		# Check joint type
		if bone_node.joint_type == PhysicalBone3D.JOINT_TYPE_PIN:
			issues.append("⚠️ %s: Using generic Pin joint (may spin unrealistically)" % bone_node.bone_name)
	
	return issues

func _set_status(text: String, color: Color = Color.WHITE):
	var label = dock.find_child("StatusLabel", true, false)
	if label:
		label.text = text
		label.add_theme_color_override("font_color", color)

class_name Player
extends CharacterBody3D
## 玩家角色。
##
## 移动由本机权威判定：谁的角色谁模拟，因此操作手感与网络延迟无关。
## 这里是有意如此选择的——第 2 阶段的目标是验证双元素协同的手感，
## 若现在就让服务端模拟玩家移动，本地必须同时实现客户端预测与位置回滚，
## 那是 netfox 一类方案覆盖的范围（设计文档 4.3）。附带说明：一旦引入
## 需要服务端判定的内容（推箱、可旋转平台、机关），那些物体改成服务端权威，
## 届时玩家移动是否一并改为"上报输入 + 服务端模拟"要等网络损伤测试的结果再定。
##
## 角色本身是胶囊体，绕 Y 轴旋转不可见，所以当前只同步位置。

const MOVE_SPEED := 6.0
const JUMP_VELOCITY := 5.0
const GRAVITY := 18.0
## 相机相对角色的固定偏移。相机设了 top_level，因而它不随角色旋转，
## 角色加上转动之后也不需要在这里做补偿。
const CAMERA_OFFSET := Vector3(0.0, 9.0, 9.0)

## 仅用于双人测试时分清谁是谁，正式的角色美术与元素表现另做。
const MOLTEN_COLOR := Color(1.0, 0.42, 0.12)
const FROST_COLOR := Color(0.36, 0.82, 0.98)

## 由 MultiplayerSpawner 的生成函数写入，各方取到的是同一个值。
var peer_id: int = 1

var _local: bool = false

@onready var _mesh: MeshInstance3D = $Mesh
@onready var _camera: Camera3D = $Camera


func _enter_tree() -> void:
	# 权限必须在这里设置，不能等到 _ready()。原因在引擎一侧：
	# 接收方会在远端生成包到达的同一帧里应用初始同步状态，而那一刻它要求节点的
	# 多人权限已经等于发起方（SceneReplicationInterface::on_replication_start 里有这个判断）。
	# 权限本身不随生成包传输，因此各端必须各自得到同一个值——
	# 这里用的是生成函数收到的 peer_id，各端由同一份数据推导，结论必然一致。
	set_multiplayer_authority(peer_id)


func _ready() -> void:
	_local = peer_id == multiplayer.get_unique_id()
	_apply_element_color()
	# 只有本机的角色参与模拟与取景，远端角色只接收同步过来的位置。
	set_physics_process(_local)
	set_process(_local)
	_camera.current = _local
	print("[player] %s角色 peer=%d 已就位" % ["本机" if _local else "远端", peer_id])


func _physics_process(delta: float) -> void:
	if not is_on_floor():
		velocity.y -= GRAVITY * delta
	elif Input.is_action_just_pressed("jump"):
		velocity.y = JUMP_VELOCITY

	var direction := Vector3(
		Input.get_axis("move_left", "move_right"),
		0.0,
		Input.get_axis("move_forward", "move_back"),
	)
	velocity.x = direction.x * MOVE_SPEED
	velocity.z = direction.z * MOVE_SPEED
	move_and_slide()


func _process(_delta: float) -> void:
	# 相机用全局坐标定位，所以它只跟随角色的位置，不跟随角色的转动。
	_camera.global_position = global_position + CAMERA_OFFSET
	_camera.look_at(global_position + Vector3.UP * 1.2, Vector3.UP)


func _apply_element_color() -> void:
	var material := StandardMaterial3D.new()
	# 一号位是「熔」，其余是「霜」。每个实例各建一份材质，避免相互影响。
	material.albedo_color = MOLTEN_COLOR if peer_id == 1 else FROST_COLOR
	_mesh.material_override = material

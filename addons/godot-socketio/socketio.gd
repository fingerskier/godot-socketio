class_name SocketIO
extends EngineIO

enum SocketPacketType {
        CONNECT,
        DISCONNECT,
        EVENT,
        ACK,
        CONNECT_ERROR,
        BINARY_EVENT,
        BINARY_ACK
}


# emit when connection to the default namespace is established
# it's not neccessary to have this signal, but most of users use the default namespace and it makes things simpler for them
signal socket_connected(ns: String)

# emit when connection to the a namespace is established
signal namespace_connected(name: String)

# emit when a namespace is disconnecte)
signal namespace_disconnected(name: String)

# emit when a namespace connection error occurred
signal namespace_connection_error(name: String, data: Variant)

# emit when an event is received
signal event_received(event: String, data: Variant, ns: String)
# emit when an event that expects an acknowledgement is received
signal event_received_ack(event: String, data: Variant, ns: String, ack_id: int)

# emit when the socket is disconnected (all namespaces have been disconnected)
signal socket_disconnected()

@export var default_namespace: String = ""
@export var socket_path = "/socket.io"
@export var reconnection: bool = true
@export var reconnection_attempts: int = 5
@export var reconnection_delay: float = 1.0
@export var reconnection_delay_factor: float = 2.0

var _namespaces := {}
var _ack_id: int = 0
var _ack_callbacks := {}
var _reconnect_timer: Timer
var _current_reconnect_attempt: int = 0
var _manual_disconnect: bool = false
var _namespaces_to_reconnect := {}

func _ready():
        self.path = socket_path
        default_namespace = _get_namespace_key(default_namespace)

        _reconnect_timer = Timer.new()
        _reconnect_timer.one_shot = true
        add_child(_reconnect_timer)
        _reconnect_timer.timeout.connect(_on_reconnect_timeout)

        _namespaces[default_namespace] = {
                "sid": "",
                "state": State.DISCONNECTED,
                "auth": {}
	}

	engine_conncetion_opened.connect(_on_engine_io_conncetion_opened)
	engine_message_received.connect(_socket_parse_packet)
	engine_conncetion_closed.connect(_on_engine_io_conncetion_closed)


## connects to the default namespace of socket server
## Usage:[br]
## [codeblock]
## var client: SocketIO = $SocketIO
## client.connect_socket()
## client.connect_socket({"token": "MY_TOKEN"})
## [/codeblock]
func connect_socket(auth: Dictionary = {}) -> void:
        if state == State.CONNECTED:
                if not _namespaces[default_namespace].state == State.CONNECTED:
                        # use might have disconnected the default namespace, in that case reconnect it
                        connect_to_namespace(default_namespace, auth)
                        return

                push_error("socket is already connected")
                return

        _manual_disconnect = false
        _reconnect_timer.stop()
        _current_reconnect_attempt = 0
        _namespaces[default_namespace].auth = auth
        engine_make_connection()
	

## connects to a namespace[br]
## Usage:[br]
## [codeblock]
## var client: SocketIO = $SocketIO
## client.connect_to_namespace() # connects to the default namespace
## connect_to_namespace("/admin") # connects to the admin namespace
## connect_to_namespace("/user", {"token": "MY_TOKEN"}) # connects to the user namespace with auth data
## [/codeblock]
func connect_to_namespace(ns: String = default_namespace, auth: Dictionary = {}):
	if not state == State.CONNECTED:
		push_error("socket is not connected, make sure to call connect_socket() first")
		return

	ns = _get_namespace_key(ns)
	if _namespaces.has(ns) and _namespaces[ns].state == State.CONNECTED:
		push_error("namespace is already connected, you must disconnect it first to make a new connection to it")
		return
	
	_namespaces[ns] = {
		"sid": "",
		"state": State.DISCONNECTED,
		"auth": auth
	}

	_send_socketio_packet(SocketPacketType.CONNECT, ns, JSON.stringify(auth) if not auth.is_empty() else "")


## emits an event to the socket server[br]
## Usage:[br]
## [codeblock]
## emit("mesage", "hello!")
## emit("message", {"text": "hello!", priority: 1})
## emit("set_port", 22)
## emit("remove_user", {"id": 22}, "/admin") # custom namespace
## [/codeblock]
func emit(event: String, data: Variant = null, ns: String = default_namespace, ack_callback: Callable = null):
        ns = _get_namespace_key(ns)
	
	if not _namespace_exists(ns):
		return
	
	if not _namespaces[ns].state == State.CONNECTED:
		push_error("namespace is not connected")
		return
	
        var id_str := ""
        if ack_callback != null:
                _ack_id += 1
                _ack_callbacks[_ack_id] = ack_callback
                id_str = str(_ack_id)

        if not data == null:
                _send_socketio_packet(SocketPacketType.EVENT, ns, "%s%s" % [id_str, JSON.stringify([event, data])])
        else:
                _send_socketio_packet(SocketPacketType.EVENT, ns, "%s%s" % [id_str, JSON.stringify([event])])

func emit_binary(event: String, bytes: PackedByteArray, ns: String = default_namespace, ack_callback: Callable = null):
        ns = _get_namespace_key(ns)
        if not _namespace_exists(ns):
                return
        if not _namespaces[ns].state == State.CONNECTED:
                push_error("namespace is not connected")
                return
        var id_str := ""
        if ack_callback != null:
                _ack_id += 1
                _ack_callbacks[_ack_id] = ack_callback
                id_str = str(_ack_id)
        var payload = JSON.stringify([event, Marshalls.raw_to_base64(bytes)])
        _send_socketio_packet(SocketPacketType.BINARY_EVENT, ns, "%s%s" % [id_str, payload])


## disconnects a namespace[br]
## Usage:[br]
## [codeblock]
## disconnect_namespace()
## disconnect_namespace("/admin")
## disconnect_namespace("/user")
## [/codeblock]
func disconnect_namespace(ns: String = default_namespace):
	ns = _get_namespace_key(ns)
	if not _namespace_exists(ns):
		return
	
	if not _namespaces[ns].state == State.CONNECTED:
		push_error("namespace is not connected")
		return
	
	_namespaces[ns].state = State.DISCONNECTED
	_send_socketio_packet(SocketPacketType.DISCONNECT, ns)


## disconnects all namespaces and closes the connection
func disconnect_socket():
        for ns in _namespaces.keys().filter(func(key): return _namespaces[key].state == State.CONNECTED):
                disconnect_namespace(ns)

        _manual_disconnect = true
        _reconnect_timer.stop()
        engine_close()
        socket_disconnected.emit()


func _on_engine_io_conncetion_closed():
        for ns in _namespaces.keys():
                if _namespaces[ns].state == State.CONNECTED:
                        _namespaces_to_reconnect[ns] = _namespaces[ns].auth
                _namespaces[ns].state = State.DISCONNECTED

        socket_disconnected.emit()

        if not _manual_disconnect and reconnection and _current_reconnect_attempt < reconnection_attempts:
                var delay = reconnection_delay * pow(reconnection_delay_factor, _current_reconnect_attempt)
                _current_reconnect_attempt += 1
                _reconnect_timer.start(delay)
        else:
                _manual_disconnect = false


func _on_engine_io_conncetion_opened():
        connect_to_namespace(default_namespace, _namespaces[default_namespace].auth)
        for ns in _namespaces_to_reconnect.keys():
                if ns != default_namespace:
                        connect_to_namespace(ns, _namespaces_to_reconnect[ns])
        _namespaces_to_reconnect.clear()
        _current_reconnect_attempt = 0


func _on_namespace_connected(ns: String, data: Variant):
	if _namespace_exists(ns):
		_namespaces[ns].state = State.CONNECTED
		_namespaces[ns].sid = data["sid"]
		namespace_connected.emit(ns)

		if ns == default_namespace:
			socket_connected.emit(ns)


func _on_namespace_disconnected(ns: String, data: Variant):
	if _namespace_exists(ns):
		_namespaces[ns].state = State.DISCONNECTED
		namespace_disconnected.emit(ns)


func _on_namespace_connect_error(ns: String, data: Variant):
	if _namespace_exists(ns):
		_namespaces[ns].state = State.DISCONNECTED
		namespace_connection_error.emit()
		push_error("namespace connection error", data)

func _on_event(ns: String, data: Array, ack_id = null):
        var event_data = data.slice(1, data.size())
        event_received.emit(data[0], event_data if event_data.size() else null, ns)
        if ack_id != null:
                event_received_ack.emit(data[0], event_data if event_data.size() else null, ns, ack_id)

func _on_ack(ns: String, ack_id: int, data: Array):
        if _ack_callbacks.has(ack_id):
                var cb = _ack_callbacks[ack_id]
                _ack_callbacks.erase(ack_id)
                cb.call_deferred(data[0] if data.size() else null)


func _binary_not_supported():
        push_error("binary packets are not supported yet")

func _on_binary_event(ns: String, data: Array, ack_id = null):
        if data.size() < 2:
                return
        var bytes = Marshalls.base64_to_raw(data[1])
        _on_event(ns, [data[0], bytes], ack_id)


func _socket_parse_packet(data: String):
        var namespace_name = _get_namespace_key(default_namespace)
        var packet_type = _get_socket_packet_type(data)
        data = data.substr(1)

        if data.begins_with("/"): # this is from a custom namespace
                var sepretator_index := data.find(",")
                if sepretator_index == -1:
                        push_error("An error occurred in parsing socket packet data, payload starts with an spash (/) but no separator found")
                        return

                namespace_name = data.substr(0, sepretator_index)
                data = data.substr(sepretator_index + 1)

        if not _namespace_exists(namespace_name):
                return

        var id: int = -1
        var idx := 0
        while idx < data.length() and data[idx].is_valid_int():
                idx += 1
        if idx > 0:
                id = int(data.substr(0, idx))
                data = data.substr(idx)

        var payload = _parse_json(data);
        if payload == null and not data.is_empty():
                return

        match packet_type:
                SocketPacketType.CONNECT:
                        _on_namespace_connected(namespace_name, payload)
                SocketPacketType.DISCONNECT:
                        _on_namespace_disconnected(namespace_name, payload)
                SocketPacketType.EVENT:
                        _on_event(namespace_name, payload, id if id != -1 else null)
                SocketPacketType.ACK:
                        _on_ack(namespace_name, id, payload)
                SocketPacketType.CONNECT_ERROR:
                        _on_namespace_connect_error(namespace_name, payload)
                SocketPacketType.BINARY_EVENT:
                        _on_binary_event(namespace_name, payload, id if id != -1 else null)
                SocketPacketType.BINARY_ACK:
                        _on_ack(namespace_name, id, payload)
	
	
func _get_socket_packet_type(data: String) -> SocketPacketType:
	if data.is_empty():
		return -1

	return int(data[0]) as SocketPacketType


func _parse_json(data: String):
	if data.is_empty():
		return null
	var json = JSON.new()
	var error = json.parse(data)
	if error != OK:
		push_error("An error occurred in parsing socket packet data" + json.get_error_message(), "\n")
		return null
		
	return json.data


func _get_namespace_key(ns: String):
	if ns.begins_with("/"):
		return ns
	
	return "/" + ns


func _namespace_exists(ns: String):
	if not _namespaces.has(ns):
		push_error("namespace not found in the client")
		return false
	
	return true


func _send_socketio_packet(type: SocketPacketType, ns: String = default_namespace, payload: String = ""):
        ns = ns if ns != "/" else ""
        if not ns.is_empty() and not payload.is_empty():
                ns += ","
        engine_send("%s%s%s" % [type, ns, payload])


func _on_reconnect_timeout():
        engine_make_connection()

func send_ack(id: int, data: Variant = null, ns: String = default_namespace):
        ns = _get_namespace_key(ns)
        if not _namespace_exists(ns):
                return
        var payload := data
        var encoded := "[]"
        if not data == null:
                encoded = JSON.stringify([data])
        _send_socketio_packet(SocketPacketType.ACK, ns, "%s%s" % [str(id), encoded])

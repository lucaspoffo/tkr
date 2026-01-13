package tkr

import "core:net"
import "core:fmt"
import "core:mem"
import "core:log"
import sa "core:container/small_array"

MAX_PACKET_SIZE :: 1000

UDP_Transport :: struct {
	socket: net.UDP_Socket,
	client_to_endpoint: map[u64]net.Endpoint,
	endpoint_to_client: map[net.Endpoint]u64,
}

udp_transport_init :: proc(udp: ^UDP_Transport, endpoint: net.Endpoint) -> (err: net.Network_Error) {
	socket := net.make_bound_udp_socket(endpoint.address, endpoint.port) or_return
	net.set_blocking(socket, false) or_return
	udp.socket = socket

	fmt.println("Initializing UDP Transport in endpoint:", endpoint)

	return err
}

udp_transport_shutdown :: proc(udp: ^UDP_Transport) {
	net.close(udp.socket)
	delete(udp.client_to_endpoint)
	delete(udp.endpoint_to_client)
	udp^ = {}
}

udp_transport_add_client :: proc(udp: ^UDP_Transport, client_id: u64, endpoint: net.Endpoint) {
	udp.client_to_endpoint[client_id] = endpoint
	udp.endpoint_to_client[endpoint] = client_id
}

udp_transport_poll :: proc(udp: ^UDP_Transport, p2p: ^$T/P2P_Session)  {
	buffer: [MAX_PACKET_SIZE]byte

	for {
		bytes_read, endpoint, err := net.recv_udp(udp.socket, buffer[:])
		if err != nil {
			if err != net.UDP_Recv_Error.Would_Block && err != net.UDP_Recv_Error.Timeout && err != net.UDP_Recv_Error.Timeout {
				log.errorf("Failed to receive udp packet: %v", err)
			}
			break
		}
		
		client_id, found_client := udp.endpoint_to_client[endpoint]
		if !found_client {
			log.errorf("Received message from invalid address %v", endpoint)
			continue
		}

		message, ok := deserialize_protocol_message(buffer[:bytes_read], p2p)
		if !ok {
			log.errorf("Failed to deserialize message from client %v (%v)", client_id, endpoint)
			continue
		}

		message.client_id = client_id
		message_to_send := p2p_process_message(p2p, message)

		if message_to_send.message != nil {
			offset, ok := serialize_protocol_message(buffer[:], p2p, message_to_send)
			if !ok {
				log.errorf("Failed to serialize message: %v", message)
				continue
			}
			net.send_udp(udp.socket, buffer[:offset], endpoint)
		}
	}
}

udp_transport_send_messages :: proc(udp: ^UDP_Transport, p2p: ^$T/P2P_Session, messages_to_send: []Protocol_Message($Input)) {
	buffer: [MAX_PACKET_SIZE]byte
	for message in messages_to_send {
		endpoint, found_address := udp.client_to_endpoint[message.client_id]
		if !found_address {
			log.errorf("Address for client %v not found when trying to send message", message.client_id)
			continue
		}

		offset, ok := serialize_protocol_message(buffer[:], p2p, message)
		
		if !ok {
			log.errorf("Failed to serialize message: %v", message)
			continue
		}

		_, err := net.send_udp(udp.socket, buffer[:offset], endpoint)
		if err != nil {
			log.errorf("Failed to send message to client %v (%v): %v", message.client_id, endpoint, err)
		}
	}
}

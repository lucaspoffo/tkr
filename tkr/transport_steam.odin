package tkr

import "core:net"
import "core:fmt"
import "core:mem"
import "core:log"
import sa "core:container/small_array"
import steam "../steamworks"

STEAM_ENABLED :: #config(STEAM_ENABLED, false)

when STEAM_ENABLED {
	steam_transport_shutdown :: proc(p2p: ^$T/P2P_Session) {
		networking_messages := steam.NetworkingMessages_SteamAPI()

		for i in 0..<p2p.num_protocols {
			network_id: steam.SteamNetworkingIdentity
			steam.NetworkingIdentity_SetSteamID(&network_id, p2p.protocols[i].client_id)
			steam.NetworkingMessages_CloseSessionWithUser(networking_messages, &network_id)
		}
	}

	steam_transport_poll :: proc(p2p: ^$T/P2P_Session) {
		send_buffer: [MAX_PACKET_SIZE]byte
		networking_messages := steam.NetworkingMessages_SteamAPI()
		
		BATCH_SIZE :: 128
		messages_buffer: [BATCH_SIZE]^steam.SteamNetworkingMessage

		num_messages := steam.NetworkingMessages_ReceiveMessagesOnChannel(networking_messages, 0, &messages_buffer[0], BATCH_SIZE)
		for i in 0..<num_messages {
			defer messages_buffer[i]->pfnRelease()
			
			if messages_buffer[i].cbSize <= 0 {
				log.error("Received message with 0 or less length")
				continue
			}

			data := mem.byte_slice(messages_buffer[i].pData, messages_buffer[i].cbSize) 
			net_id := messages_buffer[i].identityPeer
			steam_id := steam.NetworkingIdentity_GetSteamID(&net_id)
			message, ok := deserialize_protocol_message(data, p2p)
			if !ok {
				log.errorf("Failed to deserialize message from client %v", steam_id)
				continue
			}

			message.client_id = steam_id
			message_to_send := p2p_process_message(p2p, message)
			
			if message_to_send.message != nil {
				offset, ok := serialize_protocol_message(send_buffer[:], p2p, message_to_send)
				if !ok  {
					log.errorf("Failed to serialize message: %v", message_to_send)
					continue
				}
				
				nSendFlags: i32 = steam.nSteamNetworkingSend_UnreliableNoDelay | steam.nSteamNetworkingSend_AutoRestartBrokenSession
				steam.NetworkingMessages_SendMessageToUser(networking_messages, &net_id, rawptr(&send_buffer), u32(offset), nSendFlags, 0)
			}
		}
	}

	steam_transport_send_messages :: proc(p2p: ^P2P_Session($Game, $Input), messages_to_send: []Protocol_Message(Input)) {
		send_buffer: [MAX_PACKET_SIZE]byte
		networking_messages := steam.NetworkingMessages_SteamAPI()

		for message in messages_to_send {
			offset, ok := serialize_protocol_message(send_buffer[:], p2p, message)
			if !ok {
				log.errorf("Failed to serialize message: %v", message)
				continue
			}

			net_id: steam.SteamNetworkingIdentity
			steam.NetworkingIdentity_SetSteamID(&net_id, message.client_id)
			steam.NetworkingMessages_SendMessageToUser(networking_messages, &net_id, rawptr(&send_buffer), u32(offset), 0, 0)
		}
	}
}
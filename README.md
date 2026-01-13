# TK Rollback

TKR is P2P rollback network library for Odin.

Rollback Network requires the game to be deterministic, but this allows to only send inputs between peers.
Also, to predict remote players inputs so we can keep simulating gameplay without waiting,
when receiving the correct input we can rollback and re-simulate the game if necessary.

TKR has support for UDP and Steam NetworkMessages, you can also write a custom transport if needed.

https://github.com/user-attachments/assets/3e68f21a-758d-481a-a873-e2d4a7eec40e

## Code sample using UDP

For a complete usage check the example folder.

```odin
FPS :: 60.0

game: Game
local_input: Input

p2p: tkr.P2P_Session(Game, Input)
udp_transport: tkr.UDP_Transport

tkr.p2p_init(&p2p, num_players, FPS, serialize_input, deserialize_input)

// Players information usually come from a Lobby System or Matchmaking
local_player_index: u64 = 0
local_endpoint := net.Endpoint { net.IP4_Loopback, 5000 } 

remote_player_index: u64 = 1
remote_client_id: u64 = 123
remote_endpoint := net.Endpoint { net.IP4_Loopback, 5001 } 

tkr.p2p_add_local_player(&p2p, local_player_index)
tkr.p2p_add_remote_player(&p2p, remote_player_index, remote_player_index)

tkr.udp_transport_init(&udp_transport, local_endpoint)
tkr.udp_transport_add_client(&udp_transport, remote_client_id, remote_endpoint)

for game_running {
	messages_to_send := tkr.p2p_update(&p2p)
	tkr.udp_transport_send_messages(&udp_transport, &p2p, messages_to_send)
	tkr.udp_transport_poll(&udp_transport, &p2p)

	// Add local input to the simulation
	tkr.p2p_add_local_input(&p2p, client_index, local_input)

	requests, messages_to_send := tkr.p2p_advance_frame(&p2p)
	tkr.udp_transport_send_messages(&udp_transport, &p2p, messages_to_send)

	// Must handle this requests in order.
	for request in requests {
		switch &r in request {
		case tkr.Save_Game(Game):
			// Store the current game state in the given ptr
			r.game_rollback_state.state = game
			r.game_rollback_state.checksum = hash.crc32(mem.ptr_to_bytes(&game))
		case tkr.Load_Game(Game):
			// Load given game state to the global game variable
			game = r.game_rollback_state.state
		case tkr.Advance_Frame(Input):
			// Run gameplay code
			game_update(r.inputs, r.status)
		case tkr.Skip_Frames:
			// We cannot simulate more (reached the maximum Prediction Window)
			// Do nothing
		}
	}
}

game_update :: proc(inputs: [tkr.MAX_NUM_PLAYERS]Input, status: [tkr.MAX_NUM_PLAYERS]tkr.Input_Status) {
	// ... gameplay code
}
```

## Full Example

In the example folder you can check simple game example with Steam or UDP transport.

### UDP
```
odin build example
```

Commands to run a 2 player game, run each client with:
```
.\example.exe 0 127.0.0.1:5000 127.0.0.1:5001
.\example.exe 1 127.0.0.1:5000 127.0.0.1:5001
```

### Steam

When running the steam example, each client instance MUST have a different steam account.
To do this you need 2 computers (or VMs) each running different steam accounts.

```
odin build example -define:STEAM_ENABLED=true
```

Commands to run a 2 player game, run each client with (replace STEAM_IDs with your owns):
```
.\example.exe 0 <STEAM_ID_1> <STEAM_ID_2>
.\example.exe 1 <STEAM_ID_1> <STEAM_ID_2>
```

# Some resources about rollback netcode

- [GGPO: first Rollback Network library in C](https://github.com/pond3r/ggpo)
- [Analysis: Why Rollback Netcode Is Better](https://www.youtube.com/watch?v=0NLe4IpdS1w)
- [8 Frames in 16ms: Rollback Networking in Mortal Kombat and Injustice 2](https://www.youtube.com/watch?v=7jb0FOcImdg)

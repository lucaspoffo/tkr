package main

import "base:runtime"

import "core:fmt"
import "core:mem"
import "core:c"

import steam "../steamworks"

when STEAM_ENABLED {
    steam_init :: proc() {
        if steam.RestartAppIfNecessary(steam.uAppIdInvalid) {
            fmt.println("Launching app through steam...")
            return
        }

        err_msg: steam.SteamErrMsg
        if err := steam.InitFlat(&err_msg); err != .OK {
            fmt.printfln("steam.InitFlat failed with code '{}' and message \"{}\"", err, transmute(cstring)&err_msg[0])
            panic("Steam Init failed. Make sure Steam is running.")
        }

        steam.Client_SetWarningMessageHook(steam.Client(), steam_debug_text_hook)

        steam.ManualDispatch_Init()

        if !steam.User_BLoggedOn(steam.User()) {
            panic("Steam User isn't logged in.")
        } else {
            fmt.println("Steam User is logged in.")
        }
    }

    steam_debug_text_hook :: proc "c" (severity: c.int, debugText: cstring) {
        // if you're running in the debugger, only warnings (nSeverity >= 1) will be sent
        // if you add -debug_steamworksapi to the command-line, a lot of extra informational messages will also be sent
        runtime.print_string(string(debugText))

        if severity >= 1 {
            runtime.debug_trap()
        }
    }

    steam_run_callbacks :: proc() {
        temp_mem := make([dynamic]byte, context.temp_allocator)

        steam_pipe := steam.GetHSteamPipe()
        steam.ManualDispatch_RunFrame(steam_pipe)
        callback: steam.CallbackMsg

        for steam.ManualDispatch_GetNextCallback(steam_pipe, &callback) {
            // Check for dispatching API call results
            #partial switch callback.iCallback {

            case .SteamAPICallCompleted: 
                fmt.println("CallResult: ", callback)

                call_completed := transmute(^steam.SteamAPICallCompleted)callback.pubParam
                resize(&temp_mem, int(callback.cubParam))
                if temp_call_res, ok := mem.alloc(int(callback.cubParam), allocator = context.temp_allocator); ok == nil {
                    bFailed: bool
                    if steam.ManualDispatch_GetAPICallResult(steam_pipe, call_completed.hAsyncCall, temp_call_res, callback.cubParam, callback.iCallback, &bFailed) {
                        // Dispatch the call result to the registered handler(s) for the
                        // call identified by call_completed->m_hAsyncCall
                        fmt.println("   call_completed", call_completed)
                    }
                }
            case:
                // Look at callback.m_iCallback to see what kind of callback it is,
                // and dispatch to appropriate handler(s)
                // fmt.println("Callback: ", callback)
            }

            steam.ManualDispatch_FreeLastCallback(steam_pipe)
        }
    }
}

// A user-space TCP/IP stack for the phone's Linux machine.
//
// The machine emits raw Ethernet frames; this turns the guest's TCP (and
// UDP, and DNS) into real connections made with the phone's own network,
// so the container reaches anything the phone can, on any port. It is
// gvisor-tap-vsock, the same forwarder container2wasm runs on a laptop in
// its "delegate" mode, hosted here inside the app instead.
//
// The guest connects over a WebSocket on loopback (the one thing a web
// page can open to a native listener), carrying the qemu socket protocol
// AcceptQemu speaks. 192.168.127.254 is NAT'd to the host's 127.0.0.1, so
// the guest can reach a service on the phone itself.
package main

import "C"

import (
	"context"
	"fmt"
	"net"
	"net/http"
	"os"
	"sync"

	gvntypes "github.com/containers/gvisor-tap-vsock/pkg/types"
	gvnvirtualnetwork "github.com/containers/gvisor-tap-vsock/pkg/virtualnetwork"
	"golang.org/x/net/websocket"
)

var (
	once     sync.Once
	port     int
	startErr error
)

//export StartNetStack
func StartNetStack() C.int {
	once.Do(start)
	if startErr != nil {
		fmt.Fprintf(os.Stderr, "netstack: %v\n", startErr)
		return -1
	}
	return C.int(port)
}

func start() {
	config := &gvntypes.Configuration{
		MTU:               1500,
		Subnet:            "192.168.127.0/24",
		GatewayIP:         "192.168.127.1",
		GatewayMacAddress: "5a:94:ef:e4:0c:dd",
		DHCPStaticLeases:  map[string]string{"192.168.127.3": "02:00:00:00:00:01"},
		NAT:               map[string]string{"192.168.127.254": "127.0.0.1"},
		GatewayVirtualIPs: []string{"192.168.127.254"},
		Protocol:          gvntypes.QemuProtocol,
	}
	vn, err := gvnvirtualnetwork.New(config)
	if err != nil {
		startErr = err
		return
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		startErr = err
		return
	}
	port = listener.Addr().(*net.TCPAddr).Port

	mux := http.NewServeMux()
	mux.Handle("/", websocket.Handler(func(ws *websocket.Conn) {
		ws.PayloadType = websocket.BinaryFrame
		_ = vn.AcceptQemu(context.Background(), ws)
	}))
	server := &http.Server{Handler: mux}
	go func() {
		if err := server.Serve(listener); err != nil {
			fmt.Fprintf(os.Stderr, "netstack serve: %v\n", err)
		}
	}()
}

func main() {}

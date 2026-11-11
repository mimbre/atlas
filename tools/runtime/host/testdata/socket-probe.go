// socket-probe exercises bind, listen and connect without an interpreter or PATH lookup.
package main

import (
	"fmt"
	"net"
	"os"
	"time"
)

func probe(network string) error {
	address := "127.0.0.1:0"
	if network == "unix" {
		// Relative to the working directory to fit macOS's Unix socket path limit.
		address = "t.sock"
	}
	listener, err := net.Listen(network, address)
	if err != nil {
		return err
	}
	defer listener.Close()
	connection, err := net.DialTimeout(network, listener.Addr().String(), 5*time.Second)
	if err != nil {
		return err
	}
	return connection.Close()
}

func main() {
	if len(os.Args) != 2 || (os.Args[1] != "tcp4" && os.Args[1] != "unix") {
		fmt.Fprintln(os.Stderr, "usage: socket-probe tcp4|unix")
		os.Exit(2)
	}
	if err := probe(os.Args[1]); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

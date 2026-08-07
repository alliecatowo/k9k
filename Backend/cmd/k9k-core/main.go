// k9k-core is the Kubernetes-facing companion process bundled with K9k.
// It communicates exclusively through versioned, newline-delimited JSON on
// stdin/stdout; diagnostics intentionally go to stderr.
package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"

	"github.com/k9k-app/k9k/backend/internal/api"
	"github.com/k9k-app/k9k/backend/internal/kube"
)

func main() {
	cluster, err := kube.New()
	if err != nil {
		fmt.Fprintf(os.Stderr, "k9k-core: initialize Kubernetes client: %v\n", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()

	if err := api.NewServer(cluster, os.Stdin, os.Stdout).Run(ctx); err != nil {
		fmt.Fprintf(os.Stderr, "k9k-core: %v\n", err)
		os.Exit(1)
	}
}

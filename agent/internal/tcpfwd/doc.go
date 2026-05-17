// Package tcpfwd implements the site-local TCP forwarder for
// Powernode federated service delivery.
//
// Operators of subscribed services (rows in
// system_federation_service_subscriptions with site-local
// local_hostname like "localhost:5432") get their consumed services
// exposed on the local loopback interface without going through
// Traefik. The forwarder is a simple bind + pump-bytes daemon — TLS
// termination is not its concern (the SDWAN overlay provides
// transport security; site-local means no public exposure).
//
// Config file (JSON, written by Federation::TcpForwarderConfigWriter
// on the platform side):
//
//	{
//	  "forwards": [
//	    {
//	      "listen": "127.0.0.1:5432",
//	      "backend": "[fd00:b0b::20]:5432",
//	      "protocol": "tcp",
//	      "subscription_id": "<uuid>"
//	    }
//	  ]
//	}
//
// Audit: each connection is logged via slog at INFO level on
// establish and on close (with bytes-transferred counts). Production
// deployments redirect slog to systemd journal for retention.
//
// Plan reference: Decentralized Federation §L.5 + P4.6.7.
package tcpfwd

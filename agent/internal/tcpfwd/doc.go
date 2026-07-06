// Package tcpfwd implements the TCP forwarder for Powernode federated
// service delivery — originally site-local subscriptions only; as of
// campaign 019f3458 increment 4, also any tcp-protocol subscription
// (Traefik's HostSNI routing can never match plaintext TCP, so
// tcp-protocol subs ride this forwarder regardless of site-local-ness
// too — see Federation::TcpForwarderConfigWriter's class comment).
//
// Operators of subscribed services (rows in
// system_federation_service_subscriptions with site-local
// local_hostname like "localhost:5432") get their consumed services
// exposed on the local loopback interface without going through
// Traefik. The forwarder itself is protocol-agnostic about *which*
// address it binds — it's a simple bind + pump-bytes daemon reading
// whatever "listen" address its Config gives it (see Forward.Listen);
// TLS termination is not its concern (the SDWAN overlay provides
// transport security; site-local means no public exposure).
//
// Config file (JSON, written by Federation::TcpForwarderConfigWriter
// on the platform side; loaded at startup by the powernode-agent
// service loop from DefaultConfigPath):
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

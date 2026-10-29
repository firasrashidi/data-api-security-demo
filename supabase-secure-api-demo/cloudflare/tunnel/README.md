# Cloudflare Tunnel

Workers VPC uses a remotely managed Cloudflare Tunnel. The connector runs on the private EC2 instance and dials out to Cloudflare. Do not publish a hostname for the Fastify service.

Official references used for this setup:

- https://developers.cloudflare.com/workers-vpc/configuration/tunnel/
- https://developers.cloudflare.com/workers-vpc/get-started/
- https://developers.cloudflare.com/tunnel/reference/run-parameters/

`cloudflared` 2025.7.0 or newer is required. This repo pins `cloudflare/cloudflared:2026.10.5`. Workers VPC needs QUIC (`quic` or `auto`) and outbound UDP port 7844. The instance security group allows that, plus TCP 7844 as the documented HTTP/2 fallback.

## 1. Create the tunnel

You need the Cloudflare **Connectivity Directory Admin** role to create a VPC service, and **Connectivity Directory Bind** to attach it to a Worker.

1. Open the [Workers VPC dashboard](https://dash.cloudflare.com/?to=/:account/workers/vpc).
2. Open **Tunnels** and choose **Create**.
3. Name the tunnel `supabase-secure-api-demo`.
4. Save the tunnel and copy the install token. Store it as `CLOUDFLARE_TUNNEL_TOKEN`. It is shown once.
5. Copy the tunnel UUID. That is `CLOUDFLARE_TUNNEL_ID`.
6. Stop on the token screen. Do not add a published application route or a public hostname.

A Zero Trust tunnel under **Networks > Tunnels** can also produce a remotely managed token. If you create it there, skip the public hostname step. Ingress rules are for publishing an application to the internet. Workers VPC does not use them; the VPC service selects the tunnel, host, and port.

## 2. Run the connector

`aws/scripts/deploy.sh` writes the token into Secrets Manager and starts this container on the instance. The relevant compose settings are:

```yaml
image: cloudflare/cloudflared:2026.10.5
network_mode: host
command:
  - tunnel
  - --no-autoupdate
  - --protocol
  - quic
  - --edge-ip-version
  - "4"
  - run
environment:
  TUNNEL_TRANSPORT_PROTOCOL: quic
```

`TUNNEL_TOKEN` comes from the container environment, which is the supported equivalent of `--token`. The token is not placed on the process command line. `network_mode: host` lets `cloudflared` reach Fastify at `127.0.0.1:8080`. Nothing in this compose file publishes that port on a public interface.

Confirm the connector from an SSM session:

```bash
aws ssm start-session --target <instance-id> --region <region>
sudo docker compose -f /opt/secure-api/app/compose.yaml ps
sudo docker compose -f /opt/secure-api/app/compose.yaml logs --tail 50 cloudflared
```

The dashboard should show the tunnel as healthy. A log line containing `Registered tunnel connection` is the useful signal. Do not copy the token into the session transcript.

## 3. Create the VPC service

From `cloudflare/worker`, after `npm install`:

```bash
npx wrangler vpc service create secure-api-backend \
  --type http \
  --tunnel-id "$CLOUDFLARE_TUNNEL_ID" \
  --ipv4 127.0.0.1 \
  --http-port 8080
```

Save the printed service UUID as `VPC_SERVICE_ID`.

The Worker calls `env.PRIVATE_BACKEND.fetch()`. For a VPC service binding, that binding chooses the tunnel target. The URL host is only the `Host` header, and the URL port is ignored. The service's HTTP port, 8080, is the port `cloudflared` uses. The Worker hard-codes `http://127.0.0.1:8080` so a request cannot choose another backend.

## 4. Remove the tunnel

Delete the VPC service before deleting the tunnel. Dashboard: Workers VPC > VPC Services, then Tunnels. Deleting the tunnel invalidates the token. Remove the Secrets Manager value by destroying the AWS stack or by deleting that secret version after `supabase/cleanup.sql`.

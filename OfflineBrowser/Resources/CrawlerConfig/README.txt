Optional Browsertrix configuration

OfflineBrowser works without this file. Its local archive engine is the
default and does not require a server.

To enable the optional Browsertrix workflow:

1. Copy config.example.plist to config.plist in this directory.
2. Set endpoint to the HTTPS base URL of your own Browsertrix adapter,
   including its trailing path slash.
3. Set token to the matching bearer token.
4. Build the app again. config.plist is ignored by Git and must never be
   committed or shared.

The endpoint should be HTTPS in real deployments. The app sends only the
archive request metadata and receives a verified WACZ archive; the completed
archive is stored on the device.

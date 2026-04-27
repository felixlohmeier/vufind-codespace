# vufind-codespace

A GitHub Codespaces environment that automatically installs [VuFind®](https://vufind.org/) for testing purposes.

## Usage

Click the green **Code** button on GitHub and choose **Open with Codespaces → New codespace**.

The first time the Codespace starts, the `postCreateCommand` will:

1. Install **MariaDB**, **Apache**, **PHP** and **Java** (via the VuFind DEB package)
2. Download and install VuFind from the official DEB package
3. Run the VuFind installer to create the local configuration
4. Create and populate the VuFind database
5. Configure Apache and the VuFind database connection
6. Start **MariaDB**, **Apache** and **Solr**

This takes roughly 5–10 minutes. Once complete, VuFind is available at:

| Service | URL |
|---------|-----|
| VuFind  | <http://localhost:80> |
| Solr Admin UI | <http://localhost:8983/solr> |

Both ports are automatically forwarded by Codespaces.

## After resuming a Codespace

Services are restarted automatically via `postStartCommand` each time the Codespace is resumed. If a service is not running you can restart it manually:

```bash
bash .devcontainer/start-services.sh
```

## Installed components

| Component | Version / Details |
|-----------|-------------------|
| VuFind    | 11.0.2 installed to `/usr/local/vufind` |
| Database  | MariaDB — database `vufind`, user `vufind`, password `vufind` |
| Webserver | Apache 2 with `mod_rewrite` |
| Solr      | bundled with VuFind, listening on port 8983 |

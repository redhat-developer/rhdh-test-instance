# RHDH Test Instance

A comprehensive test instance setup for **Red Hat Developer Hub (RHDH)** on OpenShift, providing a ready-to-use developer portal with authentication, catalog management, and dynamic plugin support.

## Overview

This project provides automated deployment scripts and configuration files to set up a fully functional RHDH test instance on OpenShift. RHDH is Red Hat's enterprise-ready developer portal based on the open-source Backstage project, designed to unify developer tools and improve developer experience.

### Features

- 🚀 **Automated deployment** with Helm charts or Operators (Comming Soon)
- 🤖 **GitHub PR Integration** with `/test` command for on-demand deployments
- 📦 **Multiple Install Types**: Support for both Helm and Operator (Comming Soon) installation methods
- 🔄 **Flexible Version Support**: Deploy any RHDH version (latest, semantic versions like 1.7, CI builds like 1.7-98-CI)
- 🌐 **Cluster Information Sharing**: Automatic sharing of deployment URLs, OpenShift console access, and cluster credentials
- 🔐 **Integrated Keycloak Authentication**: Automatic Keycloak deployment with pre-configured realm and test users
- 👥 **Pre-configured Test Users**: Ready-to-use test accounts (test1, test2) with authentication setup
- 🏠 **Local Deployment**: Support for local development and testing environments
- ⚡ **Resource Management**: Automatic cleanup with configurable timers and resource limits
- 🎯 **Instance Limits**: Maximum of two concurrent test instances to manage resource usage
- 💬 **User-friendly feedback** with deployment status comments and live URLs
- 🛠️ **Debug & Customization Support**: Shared cluster credentials for troubleshooting and custom configurations

## GitHub PR Workflow Integration

Deploy test environments directly from Pull Requests using slash commands and test different configurations without local setup.

### Slash Commands

The bot supports flexible deployment commands directly from PR comments:

```
/test deploy <install-type> <version> [duration]
```

**Parameters:**
- `install-type`: `helm` or `operator`  (operator Comming Soon)
- `version`: Version to deploy (see supported versions below)
- `duration`: Optional cleanup timer (e.g., `4h`, `2.5h`)

**Examples:**
```
/test deploy helm 1.7 4h          # Deploy RHDH 1.7 with Helm, cleanup after 4 hours
/test deploy operator 1.6 2.5     # Deploy RHDH 1.6 with Operator, cleanup after 2.5 hours
/test deploy helm next            # Deploy latest CI version with Helm with defaut duration 3h
/test deploy operator 1.7-98-CI   # Deploy specific CI build with Operator
```

### How to Use PR Integration

1. **Comment on any PR on rhdh-test-instance repo:**
   ```
   /test deploy helm 1.7 4h
   ```

### Feedback Loop

The bot provides comprehensive feedback through PR comments for eg:

```
🚀 Deployed RHDH version: next using helm

🌐 RHDH URL: https://redhat-developer-hub-rhdh.apps.rhdh-4-17-us-east-2-kz69l.rhdh-qe.devcluster.openshift.com

🖥️ OpenShift Console: Open Console

🔑 Cluster Credentials: Available in vault under ocp-cluster-creds with keys:
• Username: CLUSTER_ADMIN_USERNAME
• Password: CLUSTER_ADMIN_PASSWORD

⏰ Cluster Availability: Next 1 hours
```

### Testing Custom Configurations via PRs

Users can deploy different configuration flavors by:

1. **Creating a PR** with modified configuration files
2. **Using bot commands** to deploy the PR's configuration:
   ```
   /test deploy helm 1.7 2h
   ```

## Local Deployment

For local development and testing environments, you can deploy RHDH directly to your OpenShift cluster.

> **Note: Bring Your Own Cluster (BYOC)**  
> Local deployment requires you to have access to your own OpenShift cluster.

### Quick Start

1. **Clone the repository:**
   ```bash
   git clone <repository-url>
   cd rhdh-test-instance
   ```

2. **Deploy RHDH with Helm:**
   ```bash
   ./install.sh helm 1.5-171-CI
   ```

3. **Or deploy with the latest main version:**
   ```bash
   ./install.sh helm next
   ```

4. **Access your RHDH instance:**
   The script will output the URL where your RHDH instance is accessible.

### Installation Methods

#### Method 1: Helm Chart Installation

```bash
./install.sh helm <version>
```

**Available versions:**
- `next` - Latest CI version
- `1.7` - Latest stable 1.7 version
- `1.6` - Latest stable 1.6 version
- `1.5` - Latest stable 1.5 version
- `1.7-98-CI` - Specific CI build
- `1.6-45-CI` - Specific CI build

**Example:**
```bash
./install.sh helm next
```

#### Method 2: Operator Installation  (Comming Soon)

```bash
./install.sh operator <version> 
```

**Example:**
```bash
./install.sh operator 1.7
```

### Accessing Your Local RHDH Instance

After successful installation, access your RHDH instance at:
```
https://redhat-developer-hub-<namespace>.<cluster-router-base>
```

### Login Process

1. Navigate to the RHDH URL
2. Click "Sign In"
3. Use one of the test users (test1/test1@123 or test2/test2@123)
4. Explore the developer portal features

## Configuration

### Application Configuration

The main application configuration is stored in `config/app-config-rhdh.yaml`:

```yaml
# Key configuration areas:
app:
  baseUrl: "${RHDH_BASE_URL}"
  
auth:
  environment: production
  providers:
    oidc:
      production:
        metadataUrl: "${KEYCLOAK_METADATA_URL}"
        clientId: "${KEYCLOAK_CLIENT_ID}"
        clientSecret: "${KEYCLOAK_CLIENT_SECRET}"

catalog:
  locations:
    - type: url
      target: https://github.com/redhat-developer/rhdh/blob/main/catalog-entities/all.yaml
```

### Dynamic Plugins

Configure dynamic plugins in `config/dynamic-plugins.yaml`:

```yaml
includes:
  - dynamic-plugins.default.yaml
plugins:
  - package: ./dynamic-plugins/dist/backstage-community-plugin-catalog-backend-module-keycloak-dynamic
    disabled: false
```

### Helm Values

Customize deployment in `helm/value_file.yaml`:

```yaml
upstream:
  backstage:
    extraAppConfig:
      - configMapRef: app-config-rhdh
        filename: app-config-rhdh.yaml
    extraEnvVarsSecrets:
      - rhdh-secrets
```

## Authentication with Keycloak

### Automatic Keycloak Deployment

The installation script automatically deploys Keycloak with:
- Admin user: `admin` / `admin123`
- Predefined realm: `rhdh`
- Pre-configured OIDC client
- Test users for development

### Test Users

The following test users are created automatically:

| Username | Password | Email | Role |
|----------|----------|--------|------|
| test1 | test1@123 | test1@redhat.com | User |
| test2 | test2@123 | test2@redhat.com | User |

### Keycloak Configuration

Keycloak is configured with:
- **Realm**: `rhdh`
- **Client ID**: `rhdh-client`

## Project Structure

```
rhdh-test-instance/
├── config/
│   ├── app-config-rhdh.yaml      # Main RHDH configuration
│   ├── dynamic-plugins.yaml      # Dynamic plugins configuration
│   └── rhdh-secrets.yaml         # Kubernetes secrets template
├── helm/
│   └── value_file.yaml           # Helm chart values
├── utils/
│   └── keycloak/
│       ├── keycloak-deploy.sh    # Keycloak deployment script
│       ├── keycloak-values.yaml  # Keycloak Helm values
│       └── rhdh-client.json      # Keycloak client configuration
├── install.sh                    # Main installation script
├── OWNERS                        # Project maintainers
└── README.md                     # This file
```

## Environment Variables

The following environment variables are used (automatically managed by the script):

| Variable | Description |
|----------|-------------|
| `RHDH_BASE_URL` | Base URL for RHDH instance |
| `KEYCLOAK_BASE_URL` | Keycloak server URL |
| `KEYCLOAK_METADATA_URL` | OIDC metadata endpoint |
| `KEYCLOAK_LOGIN_REALM` | Keycloak login realm |
| `KEYCLOAK_REALM` | Keycloak realm name |
| `KEYCLOAK_CLIENT_ID` | OIDC client ID |
| `KEYCLOAK_CLIENT_SECRET` | OIDC client secret |
| `CLUSTER_ROUTER_BASE` | OpenShift cluster router base |

## Advanced Features

### Smart Version Resolution

The framework supports flexible version specifications:

- **Semantic Versions**: `1.7`, `1.6`, `1.5` (resolves to latest patch)
- **CI Builds**: `1.7-98-CI`, `1.6-45-CI` (specific CI versions)
- **Latest**: `next` (latest CI build from main branch)

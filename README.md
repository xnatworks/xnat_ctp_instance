# CTP Docker Instance for XNAT

Dockerized [RSNA Clinical Trial Processor (CTP)](https://github.com/johnperry/CTP) that receives DICOM via C-STORE and forwards to XNAT via HTTP REST API.

CTP acts as a DICOM relay between scanners/PACS and XNAT, enabling HTTP transfer and optional de-identification.

## Quick Start

```bash
# 1. Copy and edit environment file
cp .env.example .env
# Edit .env with your XNAT URL and credentials

# 2. Start CTP
docker-compose up -d

# 3. Send DICOM to CTP
storescu -v -aec CTP localhost 1085 /path/to/file.dcm

# 4. Check CTP logs
docker exec ctp tail -20 /opt/ctp/logs/ctp.log

# 5. Check XNAT prearchive
curl -s -u admin:admin http://your-xnat/data/prearchive/projects | python3 -m json.tool
```

## Ports

| Port | Purpose |
|------|---------|
| 1085 | DICOM C-STORE (receives from scanners/PACS) |
| 1080 | CTP admin web UI |

## Admin Web Interface

CTP includes a built-in web server for administration and monitoring. Access it at:

```
http://localhost:1080
```

The landing page shows buttons for each available servlet.

**Default credentials:** `admin` / `password` (change these after first login)

| Servlet | Purpose |
|---------|---------|
| **Status** | Pipeline status - shows state of all stages (import, anonymizer, export) |
| **Configuration** | View the active `config.xml` |
| **Log** | Browse CTP log files |
| **User Manager** | Create users and assign privileges (admin only) |
| **Object Tracker** | Query the database of processed object identifiers |
| **DB Verifier** | Track status of objects inserted into external databases |
| **DICOM Anonymizer** | Edit anonymizer scripts for any DICOM anonymizer stages |
| **Script** | Edit scripts for script-based pipeline stages |
| **Lookup** | Edit lookup tables used by anonymizers |
| **System Properties** | View JVM system properties, trigger garbage collection |
| **Shutdown** | Shut down CTP (requires `king` / `password` account) |

For full details see the [CTP wiki](https://mircwiki.rsna.org/index.php?title=MIRC_CTP) and [CTP Articles](https://mircwiki.rsna.org/index.php?title=MIRC_CTP_Articles).

## Configuration

### Simple Mode (Default) - Environment Variables

The default `config.xml` is a template with `__PLACEHOLDER__` values. At container startup, `start.sh` substitutes them from environment variables defined in `.env`.

| Variable | Default | Description |
|----------|---------|-------------|
| `CTP_DICOM_PORT` | `1085` | DICOM listener port |
| `CTP_HTTP_PORT` | `1080` | Admin web UI port |
| `XNAT_URL` | `http://xnat-nginx:80` | XNAT base URL (must include port) |
| `XNAT_USERNAME` | `admin` | XNAT username |
| `XNAT_PASSWORD` | `changeme` | XNAT password |
| `XNAT_PROJECT` | `/prearchive` | Destination path |

### Custom Mode - Mount Your Own Config

For advanced setups (multiple pipelines, multiple AE titles, custom stages), mount a complete `config.xml` directly instead of using the template:

```yaml
# docker-compose.override.yml
services:
  ctp:
    volumes:
      # Remove/override the template mount and mount directly:
      - ./my-config.xml:/opt/ctp/config.xml
```

When no template is found at `/opt/ctp/config-template/config.xml`, CTP uses `/opt/ctp/config.xml` as-is with no substitution.

## Pipeline

The default pipeline:

```
Scanner/PACS --DICOM C-STORE--> CTP:1085
  --> DicomImportService (accept AET "CTP")
  --> DicomAnonymizer (pass-through by default)
  --> HttpExportService (DICOM-zip to XNAT prearchive)
```

### Anonymization

Edit `scripts/dicom-anonymizer.script` to add de-identification rules. The default script passes all tags through unchanged. See the [CTP DICOM Anonymizer docs](https://mircwiki.rsna.org/index.php?title=The_CTP_DICOM_Anonymizer) for syntax.

### HTTP Export to XNAT

CTP compresses DICOM into zip files and POSTs to XNAT's import service using JSESSION cookie authentication. The import URL is:

```
POST {XNAT_URL}/data/services/import?import-handler=DICOM-zip&inbody=true
Content-Type: application/zip
```

## Multiple AE Titles / Multiple XNAT Targets

CTP supports multiple pipelines, each with its own DICOM listener port, AE title, and export target. This requires custom mode (mounting your own `config.xml`).

### Example: Two AE Titles Routing to Two XNATs

Create a custom config with two pipelines. Each pipeline listens on a different port with a different called AE title and exports to a different XNAT:

```xml
<Configuration>
    <Server maxThreads="20" port="1080"/>

    <!-- Pipeline 1: Research scanner sends to AET "CTP_RESEARCH" on port 1085 -->
    <Pipeline name="Research XNAT Pipeline">
        <DicomImportService
            class="org.rsna.ctp.stdstages.DicomImportService"
            name="DICOM Import - Research"
            port="1085"
            root="roots/dicom-import-research"
            quarantine="quarantines/dicom-import-research">
            <accept calledAET="CTP_RESEARCH"/>
        </DicomImportService>
        <DicomAnonymizer
            name="Anonymizer - Research"
            class="org.rsna.ctp.stdstages.DicomAnonymizer"
            root="roots/anonymizer-research"
            script="scripts/dicom-anonymizer.script"
            quarantine="quarantines/anonymizer-research"/>
        <HttpExportService
            class="org.rsna.ctp.stdstages.HttpExportService"
            name="Export to Research XNAT"
            root="roots/http-export-research"
            quarantine="quarantines/http-export-research"
            contentType="application/zip"
            sendDigestHeader="yes"
            interval="5000"
            url="http://research-xnat:80/data/services/import?import-handler=DICOM-zip&amp;inbody=true">
            <compressor cacheSize="100"/>
            <xnat
                cookieName="JSESSIONID"
                url="http://research-xnat:80/data/JSESSION"
                username="admin"
                password="research-pass"/>
        </HttpExportService>
    </Pipeline>

    <!-- Pipeline 2: Clinical scanner sends to AET "CTP_CLINICAL" on port 1086 -->
    <Pipeline name="Clinical XNAT Pipeline">
        <DicomImportService
            class="org.rsna.ctp.stdstages.DicomImportService"
            name="DICOM Import - Clinical"
            port="1086"
            root="roots/dicom-import-clinical"
            quarantine="quarantines/dicom-import-clinical">
            <accept calledAET="CTP_CLINICAL"/>
        </DicomImportService>
        <DicomAnonymizer
            name="Anonymizer - Clinical"
            class="org.rsna.ctp.stdstages.DicomAnonymizer"
            root="roots/anonymizer-clinical"
            script="scripts/dicom-anonymizer.script"
            quarantine="quarantines/anonymizer-clinical"/>
        <HttpExportService
            class="org.rsna.ctp.stdstages.HttpExportService"
            name="Export to Clinical XNAT"
            root="roots/http-export-clinical"
            quarantine="quarantines/http-export-clinical"
            contentType="application/zip"
            sendDigestHeader="yes"
            interval="5000"
            url="http://clinical-xnat:80/data/services/import?import-handler=DICOM-zip&amp;inbody=true">
            <compressor cacheSize="100"/>
            <xnat
                cookieName="JSESSIONID"
                url="http://clinical-xnat:80/data/JSESSION"
                username="admin"
                password="clinical-pass"/>
        </HttpExportService>
    </Pipeline>
</Configuration>
```

### Steps to Add a Second AE Title

1. **Create your custom config** - Copy `config.xml` and replace the `__PLACEHOLDER__` values with real values. Add a second `<Pipeline>` block with a different port, AE title, root/quarantine paths, and XNAT target.

2. **Expose the additional DICOM port** in `docker-compose.override.yml`:
   ```yaml
   services:
     ctp:
       ports:
         - "1085:1085"
         - "1086:1086"   # Second pipeline
         - "1080:1080"
       volumes:
         - ./my-config.xml:/opt/ctp/config.xml
   ```

3. **Configure your scanner/PACS** to send to the appropriate AE title and port:
   - Research scanner: `CTP_RESEARCH` on port `1085`
   - Clinical scanner: `CTP_CLINICAL` on port `1086`

Each pipeline has independent root and quarantine directories so data never mixes between pipelines.

## Docker Network

CTP must be on the same Docker network as XNAT. The default `docker-compose.yml` joins `xnat_docker_compose_default` (for local xnat-docker-compose setups). Change the network name in `docker-compose.yml` to match your XNAT deployment.

## Gotchas

- **XNAT URL must include explicit port** - CTP won't infer default ports. Use `http://host:80` not `http://host`.
- **Tomcat rejects underscores in hostnames** - Use container IPs instead of Docker container names containing `_`. Find the IP with: `docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' container-name`
- **`contentType="application/zip"` is required** on `HttpExportService` - Without it CTP sends `application/x-mirc` and XNAT rejects with "Unsupported format UNKNOWN".

## Files

```
.
├── config.xml                          # CTP config template (__PLACEHOLDER__ values)
├── docker-compose.yml                  # Docker Compose service definition
├── Dockerfile                          # CTP Docker image (Eclipse Temurin JRE 17)
├── .env.example                        # Example environment variables
├── scripts/
│   └── dicom-anonymizer.script         # Anonymization rules (pass-through default)
├── start.sh                            # Entrypoint: config substitution + CTP launch
└── test-upload.sh                      # Test script for DICOM upload verification
```

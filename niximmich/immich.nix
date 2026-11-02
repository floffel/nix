# NixOS Service Configuration for Immich (niximmich)
#
# Migrated from the Docker Compose stack on saver CT 111 (immich v1.129.0,
# pgvecto-rs on PostgreSQL 14, uploads on the retired NAS share).  Two
# deliberate departures from the old layout and from the repository default:
#
#   * PostgreSQL lives *inside* this container instead of on nixpostgres.
#     Immich needs `vchord.so` in shared_preload_libraries and a search_path
#     that includes the `vectors` schema.  Both are server-wide settings, and
#     putting them on the shared cluster would change Postgres for every other
#     service.  The upstream module owns this database: it creates the role,
#     the database and every extension itself.
#   * The media library lives on this container's rootfs, not on a NAS mount.
#     Immich has no object-storage backend, so the photos are local files by
#     necessity; the nightly restic run covers them like any other guest.
#
# Because the database is reached over a Unix socket with peer authentication,
# there is no database password anywhere: no secret mount, no secretsFile.
#
# The one secret that does exist is the immich admin/API key, which is set in
# the web UI and lives in the database — so the whole state to back up is
# /var/lib/immich plus the PostgreSQL cluster, both inside this container.
{ ... }:

{
  services.immich = {
    enable = true;

    # nginx on nixnginx proxies to 10.20.20.26:2283, so the server has to
    # listen on the container's routable address; the module default of
    # "localhost" would leave the vhost with a connection-refused upstream.
    host = "0.0.0.0";
    port = 2283;

    # Module-managed PostgreSQL 17 with pgvector + VectorChord; role `immich`
    # owns database `immich`, reached through /run/postgresql.
    database = {
      enable = true;
      createDB = true;
    };

    # Module-managed redis instance on a private unix socket.
    redis.enable = true;

    # Face detection and CLIP embeddings.  Models are cached under
    # /var/cache/immich, which the module already points XDG_CACHE_HOME at.
    machine-learning.enable = true;

    mediaLocation = "/var/lib/immich";

    # Declarative system settings.  Anything listed here is reset on every
    # restart; anything omitted keeps whatever the admin set in the web UI.
    settings = {
      newVersionCheck.enabled = false;
      server.externalDomain = "https://immich.minnecker.com";
    };

    environment = {
      TZ = "Europe/Berlin";
    };
  };
}

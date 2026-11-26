/*
 * Build against an externally installed libnfs 5.x:
 * cc -Wall -Wextra -Werror scripts/nfs_readonly_probe.c $(pkg-config --cflags --libs libnfs) -o nfs_readonly_probe
 *
 * The probe accepts only an explicit NFSv3 server and export. It lists the
 * export root or reads a bounded range of an export-relative regular file.
 * Optional mount and NFS ports support servers that use fixed custom ports.
 */
#include <errno.h>
#include <fcntl.h>
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <nfsc/libnfs.h>

static int valid_component(const char *name, size_t length)
{
    if (length == 0 || length > 255 ||
        (length == 1 && name[0] == '.') ||
        (length == 2 && name[0] == '.' && name[1] == '.')) {
        return 0;
    }
    for (size_t i = 0; i < length; i++) {
        unsigned char character = name[i];
        if (character < 32 || character == 127 || character == '/' || character == '\\') {
            return 0;
        }
    }
    return 1;
}

static int valid_relative_path(const char *path)
{
    if (strlen(path) > 4095) {
        return 0;
    }
    while (1) {
        size_t length = strcspn(path, "/");
        if (!valid_component(path, length)) {
            return 0;
        }
        if (path[length] == '\0') {
            return 1;
        }
        path += length + 1;
    }
}

static int parse_uint64(const char *argument, uint64_t *value)
{
    if (argument[0] == '\0' || argument[strspn(argument, "0123456789")] != '\0') {
        return -1;
    }
    errno = 0;
    uintmax_t parsed = strtoumax(argument, NULL, 10);
    if (errno || parsed > UINT64_MAX) {
        return -1;
    }
    *value = (uint64_t)parsed;
    return 0;
}

static int list_root(struct nfs_context *nfs)
{
    struct nfsdir *directory = NULL;
    if (nfs_opendir(nfs, "/", &directory) < 0) {
        return -1;
    }
    struct nfsdirent *entry;
    int result = 0;
    while ((entry = nfs_readdir(nfs, directory)) != NULL) {
        if (!valid_component(entry->name, strlen(entry->name)) || (!S_ISDIR(entry->mode) && !S_ISREG(entry->mode))) {
            continue;
        }
        if (printf("%s\t%" PRIu64 "\t%s\n", S_ISDIR(entry->mode) ? "directory" : "file",
                   entry->size, entry->name) < 0) {
            result = -1;
            break;
        }
    }
    nfs_closedir(nfs, directory);
    return result;
}

static int read_range(struct nfs_context *nfs, const char *name, uint64_t offset, uint64_t length)
{
    char path[4097];
    snprintf(path, sizeof(path), "/%s", name);

    struct nfsfh *file = NULL;
    if (nfs_open(nfs, path, O_RDONLY | O_NOFOLLOW, &file) < 0) {
        return -1;
    }

    struct nfs_stat_64 info;
    unsigned char *buffer = NULL;
    int count = -1;
    if (nfs_fstat64(nfs, file, &info) == 0 && S_ISREG(info.nfs_mode) &&
        offset + length <= info.nfs_size) {
        buffer = malloc((size_t)length);
        if (buffer != NULL) {
            count = nfs_pread(nfs, file, offset, length, buffer);
        }
    }

    int result = -1;
    if (nfs_close(nfs, file) == 0 && count >= 0 && (uint64_t)count == length &&
        fwrite(buffer, 1, (size_t)length, stdout) == length && fflush(stdout) == 0) {
        result = 0;
    }
    free(buffer);
    return result;
}

static int usage(void)
{
    fputs("Usage: nfs_readonly_probe [--ports MOUNT NFS] SERVER /EXPORT [FILE OFFSET LENGTH]\n", stderr);
    return EXIT_FAILURE;
}

int main(int argc, char **argv)
{
    uint64_t mount_port = 0;
    uint64_t nfs_port = 0;
    uint64_t offset = 0;
    uint64_t length = 0;

    if (argc > 1 && strcmp(argv[1], "--ports") == 0) {
        if (argc < 4 || parse_uint64(argv[2], &mount_port) || parse_uint64(argv[3], &nfs_port) ||
            mount_port == 0 || mount_port > 65535 || nfs_port == 0 || nfs_port > 65535) {
            return usage();
        }
        argv += 3;
        argc -= 3;
    }
    if ((argc != 3 && argc != 6) || argv[1][0] == '\0' || argv[2][0] != '/') {
        return usage();
    }
    if (argc == 6 && (!valid_relative_path(argv[3]) || parse_uint64(argv[4], &offset) ||
                      parse_uint64(argv[5], &length) || length == 0 || length > 8 * 1024 * 1024 ||
                      offset > UINT64_MAX - length)) {
        return usage();
    }

    struct nfs_context *nfs = nfs_init_context();
    if (nfs == NULL) {
        fputs("Could not initialize libnfs.\n", stderr);
        return EXIT_FAILURE;
    }

    nfs_set_timeout(nfs, 5000);
    nfs_set_autoreconnect(nfs, 0);
    nfs_set_auto_traverse_mounts(nfs, 0);
    nfs_set_mountport(nfs, (int)mount_port);
    nfs_set_nfsport(nfs, (int)nfs_port);
    int result = nfs_set_version(nfs, 3);
    if (result == 0) {
        result = nfs_mount(nfs, argv[1], argv[2]);
    }
    if (result == 0) {
        result = argc == 3 ? list_root(nfs) : read_range(nfs, argv[3], offset, length);
    }
    if (result < 0) {
        fputs("The NFS list or bounded read failed.\n", stderr);
    }
    nfs_destroy_context(nfs);
    return result < 0 ? EXIT_FAILURE : EXIT_SUCCESS;
}

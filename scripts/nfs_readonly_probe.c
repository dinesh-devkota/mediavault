/*
 * Build against an externally installed libnfs 5.x:
 * cc -Wall -Wextra -Werror scripts/nfs_readonly_probe.c $(pkg-config --cflags --libs libnfs) -o nfs_readonly_probe
 *
 * The probe accepts only an explicit server and export. It lists the export
 * or reads a bounded range of a named top-level regular file to stdout.
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

static int valid_name(const char *name)
{
    return name[0] != '\0' && strcmp(name, ".") && strcmp(name, "..") &&
        !strchr(name, '/') && !strchr(name, '\\') && !strpbrk(name, "\r\n\t");
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
        if (!valid_name(entry->name) || (!S_ISDIR(entry->mode) && !S_ISREG(entry->mode))) {
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
    char path[257];
    if (!valid_name(name) || strlen(name) > sizeof(path) - 2 ||
        length == 0 || length > 8 * 1024 * 1024 || offset > UINT64_MAX - length) {
        return -1;
    }
    snprintf(path, sizeof(path), "/%s", name);
    struct nfs_stat_64 info;
    if (nfs_lstat64(nfs, path, &info) < 0 || !S_ISREG(info.nfs_mode) || offset + length > info.nfs_size) {
        return -1;
    }
    struct nfsfh *file = NULL;
    if (nfs_open(nfs, path, O_RDONLY, &file) < 0) {
        return -1;
    }
    unsigned char *buffer = malloc((size_t)length);
    int result = -1;
    if (buffer != NULL) {
        int count = nfs_pread(nfs, file, offset, length, buffer);
        if (count >= 0 && (uint64_t)count == length &&
            fwrite(buffer, 1, (size_t)length, stdout) == length && fflush(stdout) == 0) {
            result = 0;
        }
        free(buffer);
    }
    if (nfs_close(nfs, file) < 0) {
        result = -1;
    }
    return result;
}

int main(int argc, char **argv)
{
    uint64_t offset = 0;
    uint64_t length = 0;
    if ((argc != 3 && argc != 6) || argv[1][0] == '\0' || argv[2][0] != '/' ||
        (argc == 6 && (parse_uint64(argv[4], &offset) || parse_uint64(argv[5], &length)))) {
        fputs("Usage: nfs_readonly_probe SERVER /EXPORT [FILE OFFSET LENGTH]\n", stderr);
        return EXIT_FAILURE;
    }
    struct nfs_context *nfs = nfs_init_context();
    if (nfs == NULL) {
        fputs("Could not initialize libnfs.\n", stderr);
        return EXIT_FAILURE;
    }
    nfs_set_timeout(nfs, 5000);
    int result = nfs_mount(nfs, argv[1], argv[2]);
    if (result == 0) {
        result = argc == 3 ? list_root(nfs) : read_range(nfs, argv[3], offset, length);
    }
    if (result < 0) {
        fputs("The NFS list or bounded read failed.\n", stderr);
    }
    nfs_destroy_context(nfs);
    return result < 0 ? EXIT_FAILURE : EXIT_SUCCESS;
}

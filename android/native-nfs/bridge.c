#include <fcntl.h>
#include <jni.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <sys/time.h>
#include <nfsc/libnfs.h>

#define MAX_PATH_BYTES 4095
#define MAX_COMPONENT_BYTES 255
#define MAX_RANGE_BYTES (8 * 1024 * 1024)
#define MAX_DIRECTORY_ENTRIES 32768

static void throw_io(JNIEnv *env, const char *message)
{
    jclass type = (*env)->FindClass(env, "java/io/IOException");
    if (type != NULL) {
        (*env)->ThrowNew(env, type, message);
    }
}

static int copy_input(JNIEnv *env, jbyteArray bytes, char *output, size_t capacity)
{
    if (bytes == NULL) {
        return 0;
    }
    jsize length = (*env)->GetArrayLength(env, bytes);
    if ((size_t)length >= capacity) {
        return 0;
    }
    (*env)->GetByteArrayRegion(env, bytes, 0, length, (jbyte *)output);
    if ((*env)->ExceptionCheck(env) || memchr(output, 0, (size_t)length) != NULL) {
        return 0;
    }
    output[length] = 0;
    return 1;
}

static int valid_host(const char *host)
{
    if (*host == 0) {
        return 0;
    }
    for (; *host; host++) {
        unsigned char c = (unsigned char)*host;
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
              (c >= '0' && c <= '9') || c == '.' || c == ':' || c == '-' || c == '_')) {
            return 0;
        }
    }
    return 1;
}

static int valid_component(const char *name, size_t length)
{
    if (length == 0 || length > MAX_COMPONENT_BYTES ||
        (length == 1 && name[0] == '.') ||
        (length == 2 && name[0] == '.' && name[1] == '.')) {
        return 0;
    }
    for (size_t i = 0; i < length; i++) {
        unsigned char character = (unsigned char)name[i];
        if (character < 32 || character == 127 || character == '/' || character == '\\') {
            return 0;
        }
    }
    return 1;
}

static int valid_relative_path(const char *path, int allow_root)
{
    if (*path == 0) {
        return allow_root;
    }
    for (;;) {
        size_t length = strcspn(path, "/");
        if (!valid_component(path, length)) {
            return 0;
        }
        if (path[length] == 0) {
            return 1;
        }
        path += length + 1;
    }
}

static int make_path(JNIEnv *env, jbyteArray bytes, char *path, int allow_root)
{
    path[0] = '/';
    return copy_input(env, bytes, path + 1, MAX_PATH_BYTES + 1) &&
           valid_relative_path(path + 1, allow_root);
}

static struct nfs_context *context_from_handle(jlong handle)
{
    return (struct nfs_context *)(intptr_t)handle;
}

JNIEXPORT jlong JNICALL Java_com_dineshdevkota_cinevault_nfs_NativeNfs_connect(
    JNIEnv *env, jobject self, jbyteArray host_bytes, jbyteArray export_bytes, jint mount_port, jint nfs_port)
{
    (void)self;
    char host[256];
    char export[MAX_PATH_BYTES + 2];
    if (!copy_input(env, host_bytes, host, sizeof(host)) || !valid_host(host) ||
        !copy_input(env, export_bytes, export, sizeof(export)) || export[0] != '/' ||
        !valid_relative_path(export + 1, 1) || mount_port < 0 || mount_port > 65535 ||
        nfs_port < 0 || nfs_port > 65535) {
        if (!(*env)->ExceptionCheck(env)) {
            throw_io(env, "The NFS server or export address is invalid.");
        }
        return 0;
    }

    struct nfs_context *nfs = nfs_init_context();
    if (nfs == NULL) {
        throw_io(env, "The NFS client could not be initialized.");
        return 0;
    }
    nfs_set_timeout(nfs, 5000);
    nfs_set_autoreconnect(nfs, 0);
    nfs_set_auto_traverse_mounts(nfs, 0);
    nfs_set_mountport(nfs, mount_port);
    nfs_set_nfsport(nfs, nfs_port);
    if (nfs_set_version(nfs, 3) < 0 || nfs_mount(nfs, host, export) < 0) {
        nfs_destroy_context(nfs);
        throw_io(env, "The NFS export could not be mounted.");
        return 0;
    }
    return (jlong)(intptr_t)nfs;
}

JNIEXPORT void JNICALL Java_com_dineshdevkota_cinevault_nfs_NativeNfs_disconnect(
    JNIEnv *env, jobject self, jlong handle)
{
    (void)env;
    (void)self;
    if (handle != 0) {
        nfs_destroy_context(context_from_handle(handle));
    }
}

static int visible_entry(const struct nfsdirent *entry)
{
    return entry->name != NULL && valid_component(entry->name, strlen(entry->name)) &&
           (S_ISDIR(entry->mode) || S_ISREG(entry->mode)) && entry->size <= INT64_MAX;
}

JNIEXPORT jobjectArray JNICALL Java_com_dineshdevkota_cinevault_nfs_NativeNfs_list(
    JNIEnv *env, jobject self, jlong handle, jbyteArray path_bytes)
{
    (void)self;
    char path[MAX_PATH_BYTES + 2];
    if (handle == 0 || !make_path(env, path_bytes, path, 1)) {
        if (!(*env)->ExceptionCheck(env)) {
            throw_io(env, "The NFS directory path is invalid.");
        }
        return NULL;
    }

    struct nfs_context *nfs = context_from_handle(handle);
    struct nfsdir *directory = NULL;
    if (nfs_opendir(nfs, path, &directory) < 0) {
        throw_io(env, "The NFS directory could not be listed.");
        return NULL;
    }
    jobjectArray result = NULL;
    jsize count = 0;
    struct nfsdirent *entry = NULL;
    while ((entry = nfs_readdir(nfs, directory)) != NULL) {
        if (visible_entry(entry) && ++count > MAX_DIRECTORY_ENTRIES) {
            throw_io(env, "This NFS directory has too many entries.");
            goto finish;
        }
    }

    jclass entry_class = (*env)->FindClass(env, "com/dineshdevkota/cinevault/nfs/NativeNfs$Entry");
    if (entry_class == NULL) {
        goto finish;
    }
    jmethodID constructor = (*env)->GetMethodID(env, entry_class, "<init>", "([BZJ)V");
    if (constructor == NULL) {
        goto finish;
    }
    result = (*env)->NewObjectArray(env, count, entry_class, NULL);
    if (result == NULL) {
        goto finish;
    }
    nfs_rewinddir(nfs, directory);
    jsize index = 0;
    while ((entry = nfs_readdir(nfs, directory)) != NULL) {
        if (!visible_entry(entry)) {
            continue;
        }
        jsize length = (jsize)strlen(entry->name);
        jbyteArray name = (*env)->NewByteArray(env, length);
        if (name == NULL) {
            break;
        }
        (*env)->SetByteArrayRegion(env, name, 0, length, (const jbyte *)entry->name);
        if ((*env)->ExceptionCheck(env)) {
            (*env)->DeleteLocalRef(env, name);
            break;
        }
        jobject value = (*env)->NewObject(env, entry_class, constructor, name, (jboolean)S_ISDIR(entry->mode),
                                          (jlong)entry->size);
        (*env)->DeleteLocalRef(env, name);
        if (value == NULL) {
            break;
        }
        (*env)->SetObjectArrayElement(env, result, index++, value);
        (*env)->DeleteLocalRef(env, value);
        if ((*env)->ExceptionCheck(env)) {
            break;
        }
    }
finish:
    nfs_closedir(nfs, directory);
    return result;
}

JNIEXPORT jbyteArray JNICALL Java_com_dineshdevkota_cinevault_nfs_NativeNfs_read(
    JNIEnv *env, jobject self, jlong handle, jbyteArray path_bytes, jlong offset, jint length)
{
    (void)self;
    char path[MAX_PATH_BYTES + 2];
    if (handle == 0 || !make_path(env, path_bytes, path, 0) ||
        offset < 0 || length < 1 || length > MAX_RANGE_BYTES || offset > INT64_MAX - length) {
        if (!(*env)->ExceptionCheck(env)) {
            throw_io(env, "The NFS read range or path is invalid.");
        }
        return NULL;
    }

    struct nfs_context *nfs = context_from_handle(handle);
    struct nfsfh *file = NULL;
    if (nfs_open(nfs, path, O_RDONLY | O_NOFOLLOW, &file) < 0) {
        throw_io(env, "The NFS file could not be opened.");
        return NULL;
    }
    struct nfs_stat_64 info;
    jbyteArray result = NULL;
    unsigned char *buffer = NULL;
    int count = -1;
    if (nfs_fstat64(nfs, file, &info) == 0 && S_ISREG(info.nfs_mode) &&
        (uint64_t)offset + (uint64_t)length <= info.nfs_size) {
        buffer = malloc((size_t)length);
        if (buffer != NULL) {
            count = nfs_pread(nfs, file, (uint64_t)offset, (uint64_t)length, buffer);
        }
    }
    if (nfs_close(nfs, file) == 0 && count == length) {
        result = (*env)->NewByteArray(env, length);
        if (result != NULL) {
            (*env)->SetByteArrayRegion(env, result, 0, length, (const jbyte *)buffer);
        }
    } else {
        throw_io(env, "The NFS server did not return the complete byte range.");
    }
    free(buffer);
    return result;
}

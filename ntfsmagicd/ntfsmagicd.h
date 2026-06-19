#ifndef NTFSMAGICD_H
#define NTFSMAGICD_H

#include <stdint.h>

#pragma pack(push, 1)

#define NTFSMAGICD_SOCKET_PATH "/tmp/ntfsmagicd.sock"

enum ntfs_msg_type {
    NTFS_MSG_MOUNT = 1,
    NTFS_MSG_UNMOUNT,
    NTFS_MSG_GETATTR,
    NTFS_MSG_LOOKUP,
    NTFS_MSG_READDIR,
    NTFS_MSG_READ,
    NTFS_MSG_WRITE,
    NTFS_MSG_CREATE,
    NTFS_MSG_MKDIR,
    NTFS_MSG_UNLINK,
    NTFS_MSG_RMDIR,
    NTFS_MSG_RENAME,
    NTFS_MSG_TRUNCATE
};

struct ntfs_msg_header {
    uint32_t length;     // total length including payload
    uint32_t type;       // ntfs_msg_type
    uint64_t request_id;
};

struct ntfs_msg_mount_req {
    char device[128];
};

struct ntfs_msg_mount_resp {
    int32_t status;
    uint64_t root_ino;
};

struct ntfs_msg_unmount_req {
    uint64_t unused;
};

struct ntfs_msg_unmount_resp {
    int32_t status;
};

struct ntfs_msg_getattr_req {
    uint64_t ino;
};

struct ntfs_msg_getattr_resp {
    int32_t status;
    uint64_t size;
    uint32_t mode;      // permissions & type
    uint32_t nlink;
    uint64_t mtime;     // epoch in seconds
    uint64_t ctime;
    uint64_t atime;
};

struct ntfs_msg_lookup_req {
    uint64_t parent_ino;
    char name[256];
};

struct ntfs_msg_lookup_resp {
    int32_t status;
    uint64_t ino;
    uint64_t size;
    uint32_t mode;
};

struct ntfs_msg_readdir_req {
    uint64_t ino;
    uint64_t offset;
};

struct ntfs_dirent {
    uint64_t ino;
    uint32_t type;
    char name[256];
};

struct ntfs_msg_readdir_resp {
    int32_t status;
    uint32_t count;
    struct ntfs_dirent entries[128];
};

struct ntfs_msg_read_req {
    uint64_t ino;
    uint64_t offset;
    uint32_t size;
};

struct ntfs_msg_read_resp {
    int32_t status;
    uint32_t size;
    char data[0]; // followed by dynamic data
};

struct ntfs_msg_write_req {
    uint64_t ino;
    uint64_t offset;
    uint32_t size;
    char data[0];
};

struct ntfs_msg_write_resp {
    int32_t status;
    uint32_t size;
};

struct ntfs_msg_create_req {
    uint64_t parent_ino;
    uint32_t mode;
    char name[256];
};

struct ntfs_msg_create_resp {
    int32_t status;
    uint64_t ino;
};

struct ntfs_msg_mkdir_req {
    uint64_t parent_ino;
    char name[256];
};

struct ntfs_msg_mkdir_resp {
    int32_t status;
    uint64_t ino;
};

struct ntfs_msg_unlink_req {
    uint64_t parent_ino;
    char name[256];
};

struct ntfs_msg_unlink_resp {
    int32_t status;
};

struct ntfs_msg_rmdir_req {
    uint64_t parent_ino;
    char name[256];
};

struct ntfs_msg_rmdir_resp {
    int32_t status;
};

struct ntfs_msg_rename_req {
    uint64_t old_parent_ino;
    uint64_t new_parent_ino;
    char old_name[256];
    char new_name[256];
};

struct ntfs_msg_rename_resp {
    int32_t status;
};

struct ntfs_msg_truncate_req {
    uint64_t ino;
    uint64_t size;
};

struct ntfs_msg_truncate_resp {
    int32_t status;
};

#pragma pack(pop)

#endif

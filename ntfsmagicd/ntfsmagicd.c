#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/socket.h>
#include <sys/un.h>
#include <errno.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <pthread.h>

#include <ntfs-3g/volume.h>
#include <ntfs-3g/inode.h>
#include <ntfs-3g/dir.h>
#include <ntfs-3g/attrib.h>
#include <ntfs-3g/unistr.h>
#include <ntfs-3g/layout.h>
#include <ntfs-3g/ntfstime.h>

#include "ntfsmagicd.h"

ntfs_volume *g_vol = NULL;
pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;

#define INODE_CACHE_SIZE 16

struct cache_entry {
    uint64_t ino;
    ntfs_inode *ni;
    uint64_t last_use;
};

struct cache_entry g_inode_cache[INODE_CACHE_SIZE];
uint64_t g_cache_timer = 0;

void cache_init(void) {
    memset(g_inode_cache, 0, sizeof(g_inode_cache));
    g_cache_timer = 0;
}

ntfs_inode *cache_get_inode(uint64_t ino) {
    g_cache_timer++;
    // Check if already in cache
    for (int i = 0; i < INODE_CACHE_SIZE; i++) {
        if (g_inode_cache[i].ni && g_inode_cache[i].ino == ino) {
            g_inode_cache[i].last_use = g_cache_timer;
            return g_inode_cache[i].ni;
        }
    }
    
    // Find empty slot or LRU slot to evict
    int target_idx = -1;
    uint64_t oldest_time = (uint64_t)-1;
    
    for (int i = 0; i < INODE_CACHE_SIZE; i++) {
        if (!g_inode_cache[i].ni) {
            target_idx = i;
            break;
        }
        if (g_inode_cache[i].last_use < oldest_time) {
            oldest_time = g_inode_cache[i].last_use;
            target_idx = i;
        }
    }
    
    // Evict oldest if necessary
    if (g_inode_cache[target_idx].ni) {
        printf("[ntfsmagicd] Inode cache full. Evicting inode %llu\n", (unsigned long long)g_inode_cache[target_idx].ino);
        ntfs_inode_close(g_inode_cache[target_idx].ni);
        g_inode_cache[target_idx].ni = NULL;
        g_inode_cache[target_idx].ino = 0;
    }
    
    // Open new inode
    ntfs_inode *ni = ntfs_inode_open(g_vol, ino);
    if (ni) {
        g_inode_cache[target_idx].ino = ino;
        g_inode_cache[target_idx].ni = ni;
        g_inode_cache[target_idx].last_use = g_cache_timer;
    }
    return ni;
}

void cache_evict(uint64_t ino) {
    for (int i = 0; i < INODE_CACHE_SIZE; i++) {
        if (g_inode_cache[i].ni && g_inode_cache[i].ino == ino) {
            printf("[ntfsmagicd] Evicting inode %llu from cache\n", (unsigned long long)ino);
            ntfs_inode_close(g_inode_cache[i].ni);
            g_inode_cache[i].ni = NULL;
            g_inode_cache[i].ino = 0;
            break;
        }
    }
}

void cache_close_all(void) {
    printf("[ntfsmagicd] Closing all cached inodes...\n");
    for (int i = 0; i < INODE_CACHE_SIZE; i++) {
        if (g_inode_cache[i].ni) {
            ntfs_inode_close(g_inode_cache[i].ni);
            g_inode_cache[i].ni = NULL;
            g_inode_cache[i].ino = 0;
        }
    }
}

struct readdir_ctx {
    struct ntfs_dirent *entries;
    int max_entries;
    int count;
};

static int readdir_callback(void *dirent, const ntfschar *name,
                            const int name_len, const int name_type, const s64 pos,
                            const MFT_REF mref, const unsigned dt_type)
{
    struct readdir_ctx *ctx = (struct readdir_ctx *)dirent;
    if (ctx->count >= ctx->max_entries) {
        return -1; // stop
    }
    
    if (name_type == FILE_NAME_DOS) {
        return 0; // skip DOS-only names
    }
    
    char *utf8_name = NULL;
    int len = ntfs_ucstombs(name, name_len, &utf8_name, 0);
    if (len < 0) {
        return 0; // ignore decode errors
    }
    
    // Skip "." and ".."
    if (strcmp(utf8_name, ".") == 0 || strcmp(utf8_name, "..") == 0) {
        free(utf8_name);
        return 0;
    }
    
    struct ntfs_dirent *entry = &ctx->entries[ctx->count];
    entry->ino = MREF(mref);
    entry->type = dt_type;
    strncpy(entry->name, utf8_name, sizeof(entry->name) - 1);
    entry->name[sizeof(entry->name) - 1] = '\0';
    free(utf8_name);
    
    ctx->count++;
    return 0;
}

static void handle_client(int client_fd) {
    while (1) {
        struct ntfs_msg_header hdr;
        ssize_t n = read(client_fd, &hdr, sizeof(hdr));
        if (n <= 0) {
            break; // client disconnected
        }
        
        uint32_t payload_len = hdr.length - sizeof(hdr);
        char *payload = NULL;
        if (payload_len > 0) {
            payload = malloc(payload_len);
            if (!payload) {
                // Out of memory
                break;
            }
            ssize_t bytes_read = 0;
            while (bytes_read < payload_len) {
                ssize_t r = read(client_fd, payload + bytes_read, payload_len - bytes_read);
                if (r <= 0) {
                    free(payload);
                    return;
                }
                bytes_read += r;
            }
        }
        
        pthread_mutex_lock(&g_lock);
        
        if (hdr.type == NTFS_MSG_MOUNT) {
            struct ntfs_msg_mount_req *req = (struct ntfs_msg_mount_req *)payload;
            struct ntfs_msg_mount_resp resp;
            memset(&resp, 0, sizeof(resp));
            resp.status = 0;
            resp.root_ino = 0;
            
            if (g_vol) {
                resp.status = -EBUSY;
            } else {
                printf("[ntfsmagicd] Mounting device: %s\n", req->device);
                ntfs_volume *vol = ntfs_mount(req->device, NTFS_MNT_RECOVER | NTFS_MNT_IGNORE_HIBERFILE);
                if (!vol) {
                    resp.status = -errno;
                    printf("[ntfsmagicd] Mount failed: %s (errno=%d)\n", strerror(errno), errno);
                } else {
                    g_vol = vol;
                    resp.root_ino = 5; // NTFS Root directory is MFT 5
                    resp.block_size = vol->cluster_size;
                    resp.total_blocks = vol->nr_clusters;
                    
                    if (ntfs_volume_get_free_space(vol) < 0) {
                        resp.free_blocks = vol->free_clusters >= 0 ? vol->free_clusters : vol->nr_clusters / 2;
                    } else {
                        resp.free_blocks = vol->free_clusters;
                    }
                    
                    cache_init();
                    
                    printf("[ntfsmagicd] Mount successful! Volume name: '%s', Root inode: %lld, Block size: %u, Total blocks: %lld, Free blocks: %lld\n",
                           vol->vol_name ? vol->vol_name : "None", (long long)resp.root_ino, resp.block_size, (long long)resp.total_blocks, (long long)resp.free_blocks);
                }
            }
            
            struct ntfs_msg_header resp_hdr;
            resp_hdr.length = sizeof(resp_hdr) + sizeof(resp);
            resp_hdr.type = NTFS_MSG_MOUNT;
            resp_hdr.request_id = hdr.request_id;
            
            write(client_fd, &resp_hdr, sizeof(resp_hdr));
            write(client_fd, &resp, sizeof(resp));
        }
        else if (hdr.type == NTFS_MSG_UNMOUNT) {
            struct ntfs_msg_unmount_resp resp;
            resp.status = 0;
            
            if (!g_vol) {
                resp.status = -EINVAL;
            } else {
                printf("[ntfsmagicd] Unmounting device\n");
                cache_close_all();
                int r = ntfs_umount(g_vol, FALSE);
                if (r < 0) {
                    resp.status = -errno;
                } else {
                    g_vol = NULL;
                }
            }
            
            struct ntfs_msg_header resp_hdr;
            resp_hdr.length = sizeof(resp_hdr) + sizeof(resp);
            resp_hdr.type = NTFS_MSG_UNMOUNT;
            resp_hdr.request_id = hdr.request_id;
            
            write(client_fd, &resp_hdr, sizeof(resp_hdr));
            write(client_fd, &resp, sizeof(resp));
        }
        else {
            // All operations below require volume to be mounted
            if (!g_vol) {
                // Send back ENOTCONN error
                struct ntfs_msg_header resp_hdr;
                resp_hdr.length = sizeof(resp_hdr) + sizeof(int32_t);
                resp_hdr.type = hdr.type;
                resp_hdr.request_id = hdr.request_id;
                int32_t status = -ENOTCONN;
                write(client_fd, &resp_hdr, sizeof(resp_hdr));
                write(client_fd, &status, sizeof(status));
                
                pthread_mutex_unlock(&g_lock);
                if (payload) free(payload);
                continue;
            }
            
            switch (hdr.type) {
                case NTFS_MSG_GETATTR: {
                    struct ntfs_msg_getattr_req *req = (struct ntfs_msg_getattr_req *)payload;
                    struct ntfs_msg_getattr_resp resp;
                    memset(&resp, 0, sizeof(resp));
                    
                    ntfs_inode *ni = cache_get_inode(req->ino);
                    if (!ni) {
                        resp.status = -errno;
                    } else {
                        resp.status = 0;
                        resp.size = ni->data_size;
                        resp.nlink = 1; // Simplification
                        
                        if (ni->flags & FILE_ATTR_DIRECTORY) {
                            resp.mode = S_IFDIR | 0777;
                        } else if (ni->flags & FILE_ATTR_REPARSE_POINT) {
                            resp.mode = S_IFLNK | 0777;
                        } else {
                            resp.mode = S_IFREG | 0777;
                        }
                        
                        resp.mtime = ntfs2timespec(ni->last_data_change_time).tv_sec;
                        resp.ctime = ntfs2timespec(ni->last_mft_change_time).tv_sec;
                        resp.atime = ntfs2timespec(ni->last_access_time).tv_sec;
                    }
                    
                    struct ntfs_msg_header resp_hdr;
                    resp_hdr.length = sizeof(resp_hdr) + sizeof(resp);
                    resp_hdr.type = NTFS_MSG_GETATTR;
                    resp_hdr.request_id = hdr.request_id;
                    
                    write(client_fd, &resp_hdr, sizeof(resp_hdr));
                    write(client_fd, &resp, sizeof(resp));
                    break;
                }
                case NTFS_MSG_LOOKUP: {
                    struct ntfs_msg_lookup_req *req = (struct ntfs_msg_lookup_req *)payload;
                    struct ntfs_msg_lookup_resp resp;
                    memset(&resp, 0, sizeof(resp));
                    
                    ntfs_inode *dir_ni = cache_get_inode(req->parent_ino);
                    if (!dir_ni) {
                        resp.status = -errno;
                    } else {
                        u64 mref = ntfs_inode_lookup_by_mbsname(dir_ni, req->name);
                        
                        if (mref == (u64)-1) {
                            resp.status = -ENOENT;
                        } else {
                            u64 ino = MREF(mref);
                            ntfs_inode *ni = cache_get_inode(ino);
                            if (!ni) {
                                resp.status = -errno;
                            } else {
                                resp.status = 0;
                                resp.ino = ino;
                                resp.size = ni->data_size;
                                if (ni->flags & FILE_ATTR_DIRECTORY) {
                                    resp.mode = S_IFDIR | 0777;
                                } else if (ni->flags & FILE_ATTR_REPARSE_POINT) {
                                    resp.mode = S_IFLNK | 0777;
                                } else {
                                    resp.mode = S_IFREG | 0777;
                                }
                            }
                        }
                    }
                    
                    struct ntfs_msg_header resp_hdr;
                    resp_hdr.length = sizeof(resp_hdr) + sizeof(resp);
                    resp_hdr.type = NTFS_MSG_LOOKUP;
                    resp_hdr.request_id = hdr.request_id;
                    
                    write(client_fd, &resp_hdr, sizeof(resp_hdr));
                    write(client_fd, &resp, sizeof(resp));
                    break;
                }
                case NTFS_MSG_READDIR: {
                    struct ntfs_msg_readdir_req *req = (struct ntfs_msg_readdir_req *)payload;
                    struct ntfs_msg_readdir_resp resp;
                    memset(&resp, 0, sizeof(resp));
                    
                    ntfs_inode *dir_ni = cache_get_inode(req->ino);
                    if (!dir_ni) {
                        resp.status = -errno;
                    } else {
                        struct readdir_ctx readdir_ctx;
                        readdir_ctx.entries = resp.entries;
                        readdir_ctx.max_entries = 128;
                        readdir_ctx.count = 0;
                        
                        s64 pos = req->offset;
                        int r = ntfs_readdir(dir_ni, &pos, &readdir_ctx, readdir_callback);
                        
                        if (r < 0) {
                            resp.status = -errno;
                        } else {
                            resp.status = 0;
                            resp.count = readdir_ctx.count;
                        }
                    }
                    
                    struct ntfs_msg_header resp_hdr;
                    resp_hdr.length = sizeof(resp_hdr) + sizeof(resp);
                    resp_hdr.type = NTFS_MSG_READDIR;
                    resp_hdr.request_id = hdr.request_id;
                    
                    write(client_fd, &resp_hdr, sizeof(resp_hdr));
                    write(client_fd, &resp, sizeof(resp));
                    break;
                }
                case NTFS_MSG_READ: {
                    struct ntfs_msg_read_req *req = (struct ntfs_msg_read_req *)payload;
                    
                    // Allocate response with space for data dynamically
                    uint32_t buf_size = req->size;
                    struct ntfs_msg_read_resp *resp = malloc(sizeof(struct ntfs_msg_read_resp) + buf_size);
                    memset(resp, 0, sizeof(struct ntfs_msg_read_resp) + buf_size);
                    
                    ntfs_inode *ni = cache_get_inode(req->ino);
                    if (!ni) {
                        resp->status = -errno;
                        resp->size = 0;
                    } else {
                        // Read unnamed data stream
                        int bytes_read = ntfs_attr_data_read(ni, NULL, 0, resp->data, buf_size, req->offset);
                        
                        if (bytes_read < 0) {
                            resp->status = -errno;
                            resp->size = 0;
                        } else {
                            resp->status = 0;
                            resp->size = bytes_read;
                        }
                    }
                    
                    struct ntfs_msg_header resp_hdr;
                    resp_hdr.length = sizeof(resp_hdr) + sizeof(struct ntfs_msg_read_resp) + resp->size;
                    resp_hdr.type = NTFS_MSG_READ;
                    resp_hdr.request_id = hdr.request_id;
                    
                    write(client_fd, &resp_hdr, sizeof(resp_hdr));
                    write(client_fd, resp, sizeof(struct ntfs_msg_read_resp) + resp->size);
                    free(resp);
                    break;
                }
                case NTFS_MSG_WRITE: {
                    struct ntfs_msg_write_req *req = (struct ntfs_msg_write_req *)payload;
                    struct ntfs_msg_write_resp resp;
                    memset(&resp, 0, sizeof(resp));
                    
                    ntfs_inode *ni = cache_get_inode(req->ino);
                    if (!ni) {
                        resp.status = -errno;
                    } else {
                        int bytes_written = ntfs_attr_data_write(ni, NULL, 0, req->data, req->size, req->offset);
                        
                        if (bytes_written < 0) {
                            resp.status = -errno;
                            resp.size = 0;
                        } else {
                            resp.status = 0;
                            resp.size = bytes_written;
                        }
                    }
                    
                    struct ntfs_msg_header resp_hdr;
                    resp_hdr.length = sizeof(resp_hdr) + sizeof(resp);
                    resp_hdr.type = NTFS_MSG_WRITE;
                    resp_hdr.request_id = hdr.request_id;
                    
                    write(client_fd, &resp_hdr, sizeof(resp_hdr));
                    write(client_fd, &resp, sizeof(resp));
                    break;
                }
                case NTFS_MSG_CREATE: {
                    struct ntfs_msg_create_req *req = (struct ntfs_msg_create_req *)payload;
                    struct ntfs_msg_create_resp resp;
                    memset(&resp, 0, sizeof(resp));
                    
                    ntfs_inode *dir_ni = cache_get_inode(req->parent_ino);
                    if (!dir_ni) {
                        resp.status = -errno;
                    } else {
                        ntfschar *uname = NULL;
                        int uname_len = ntfs_mbstoucs(req->name, &uname);
                        if (uname_len < 0) {
                            resp.status = -errno;
                        } else {
                            // Create regular file
                            ntfs_inode *new_ni = ntfs_create(dir_ni, 0, uname, uname_len, S_IFREG);
                            free(uname);
                            
                            if (!new_ni) {
                                resp.status = -errno;
                            } else {
                                resp.status = 0;
                                resp.ino = new_ni->mft_no;
                                ntfs_inode_close(new_ni);
                            }
                        }
                        cache_evict(req->parent_ino);
                    }
                    
                    struct ntfs_msg_header resp_hdr;
                    resp_hdr.length = sizeof(resp_hdr) + sizeof(resp);
                    resp_hdr.type = NTFS_MSG_CREATE;
                    resp_hdr.request_id = hdr.request_id;
                    
                    write(client_fd, &resp_hdr, sizeof(resp_hdr));
                    write(client_fd, &resp, sizeof(resp));
                    break;
                }
                case NTFS_MSG_MKDIR: {
                    struct ntfs_msg_mkdir_req *req = (struct ntfs_msg_mkdir_req *)payload;
                    struct ntfs_msg_mkdir_resp resp;
                    memset(&resp, 0, sizeof(resp));
                    
                    ntfs_inode *dir_ni = cache_get_inode(req->parent_ino);
                    if (!dir_ni) {
                        resp.status = -errno;
                    } else {
                        ntfschar *uname = NULL;
                        int uname_len = ntfs_mbstoucs(req->name, &uname);
                        if (uname_len < 0) {
                            resp.status = -errno;
                        } else {
                            // Create directory
                            ntfs_inode *new_ni = ntfs_create(dir_ni, 0, uname, uname_len, S_IFDIR);
                            free(uname);
                            
                            if (!new_ni) {
                                resp.status = -errno;
                            } else {
                                resp.status = 0;
                                resp.ino = new_ni->mft_no;
                                ntfs_inode_close(new_ni);
                            }
                        }
                        cache_evict(req->parent_ino);
                    }
                    
                    struct ntfs_msg_header resp_hdr;
                    resp_hdr.length = sizeof(resp_hdr) + sizeof(resp);
                    resp_hdr.type = NTFS_MSG_MKDIR;
                    resp_hdr.request_id = hdr.request_id;
                    
                    write(client_fd, &resp_hdr, sizeof(resp_hdr));
                    write(client_fd, &resp, sizeof(resp));
                    break;
                }
                case NTFS_MSG_UNLINK: {
                    struct ntfs_msg_unlink_req *req = (struct ntfs_msg_unlink_req *)payload;
                    struct ntfs_msg_unlink_resp resp;
                    memset(&resp, 0, sizeof(resp));
                    
                    ntfs_inode *dir_ni = cache_get_inode(req->parent_ino);
                    if (!dir_ni) {
                        resp.status = -errno;
                    } else {
                        u64 mref = ntfs_inode_lookup_by_mbsname(dir_ni, req->name);
                        if (mref == (u64)-1) {
                            resp.status = -ENOENT;
                        } else {
                            u64 ino = MREF(mref);
                            // Evict both target and parent directory before opening duplicate handles
                            cache_evict(ino);
                            cache_evict(req->parent_ino);
                            
                            ntfs_inode *ni = ntfs_inode_open(g_vol, ino);
                            if (!ni) {
                                resp.status = -errno;
                            } else {
                                ntfs_inode *dir_ni_dup = ntfs_inode_open(g_vol, req->parent_ino);
                                if (!dir_ni_dup) {
                                    resp.status = -errno;
                                    ntfs_inode_close(ni);
                                } else {
                                    ntfschar *uname = NULL;
                                    int uname_len = ntfs_mbstoucs(req->name, &uname);
                                    int r = ntfs_delete(g_vol, NULL, ni, dir_ni_dup, uname, uname_len);
                                    free(uname);
                                    
                                    if (r < 0) {
                                        resp.status = -errno;
                                    } else {
                                        resp.status = 0;
                                    }
                                }
                            }
                        }
                    }
                    
                    struct ntfs_msg_header resp_hdr;
                    resp_hdr.length = sizeof(resp_hdr) + sizeof(resp);
                    resp_hdr.type = NTFS_MSG_UNLINK;
                    resp_hdr.request_id = hdr.request_id;
                    
                    write(client_fd, &resp_hdr, sizeof(resp_hdr));
                    write(client_fd, &resp, sizeof(resp));
                    break;
                }
                case NTFS_MSG_RMDIR: {
                    struct ntfs_msg_rmdir_req *req = (struct ntfs_msg_rmdir_req *)payload;
                    struct ntfs_msg_rmdir_resp resp;
                    memset(&resp, 0, sizeof(resp));
                    
                    ntfs_inode *dir_ni = cache_get_inode(req->parent_ino);
                    if (!dir_ni) {
                        resp.status = -errno;
                    } else {
                        u64 mref = ntfs_inode_lookup_by_mbsname(dir_ni, req->name);
                        if (mref == (u64)-1) {
                            resp.status = -ENOENT;
                        } else {
                            u64 ino = MREF(mref);
                            // Evict both target and parent directory before opening duplicate handles
                            cache_evict(ino);
                            cache_evict(req->parent_ino);
                            
                            ntfs_inode *ni = ntfs_inode_open(g_vol, ino);
                            if (!ni) {
                                resp.status = -errno;
                            } else {
                                ntfs_inode *dir_ni_dup = ntfs_inode_open(g_vol, req->parent_ino);
                                if (!dir_ni_dup) {
                                    resp.status = -errno;
                                    ntfs_inode_close(ni);
                                } else {
                                    ntfschar *uname = NULL;
                                    int uname_len = ntfs_mbstoucs(req->name, &uname);
                                    int r = ntfs_delete(g_vol, NULL, ni, dir_ni_dup, uname, uname_len);
                                    free(uname);
                                    
                                    if (r < 0) {
                                        resp.status = -errno;
                                    } else {
                                        resp.status = 0;
                                    }
                                }
                            }
                        }
                    }
                    
                    struct ntfs_msg_header resp_hdr;
                    resp_hdr.length = sizeof(resp_hdr) + sizeof(resp);
                    resp_hdr.type = NTFS_MSG_RMDIR;
                    resp_hdr.request_id = hdr.request_id;
                    
                    write(client_fd, &resp_hdr, sizeof(resp_hdr));
                    write(client_fd, &resp, sizeof(resp));
                    break;
                }
                case NTFS_MSG_RENAME: {
                    struct ntfs_msg_rename_req *req = (struct ntfs_msg_rename_req *)payload;
                    printf("[ntfsmagicd] RENAME: old_parent=%llu, new_parent=%llu\n", (unsigned long long)req->old_parent_ino, (unsigned long long)req->new_parent_ino);
                    printf("[ntfsmagicd] RENAME: old_name='%s' (len=%zu), new_name='%s' (len=%zu)\n", req->old_name, strlen(req->old_name), req->new_name, strlen(req->new_name));
                    struct ntfs_msg_rename_resp resp;
                    memset(&resp, 0, sizeof(resp));
                    
                    ntfs_inode *lookup_dir = cache_get_inode(req->old_parent_ino);
                    if (!lookup_dir) {
                        resp.status = -errno;
                    } else {
                        u64 mref = ntfs_inode_lookup_by_mbsname(lookup_dir, req->old_name);
                        if (mref == (u64)-1) {
                            resp.status = -ENOENT;
                        } else {
                            u64 ino = MREF(mref);
                            // Evict all involved inodes from cache before modifying them
                            cache_evict(ino);
                            cache_evict(req->old_parent_ino);
                            cache_evict(req->new_parent_ino);
                            
                            ntfs_inode *ni = ntfs_inode_open(g_vol, ino);
                            if (!ni) {
                                resp.status = -errno;
                            } else {
                                if (req->old_parent_ino == req->new_parent_ino) {
                                    ntfs_inode *dir_ni = ntfs_inode_open(g_vol, req->old_parent_ino);
                                    if (!dir_ni) {
                                        resp.status = -errno;
                                        ntfs_inode_close(ni);
                                    } else {
                                        ntfschar *new_uname = NULL;
                                        int new_uname_len = ntfs_mbstoucs(req->new_name, &new_uname);
                                        int r = ntfs_link(ni, dir_ni, new_uname, new_uname_len);
                                        free(new_uname);
                                        
                                        if (r < 0) {
                                            printf("[ntfsmagicd] ntfs_link failed: %d, errno=%d\n", r, errno);
                                            resp.status = -errno;
                                            ntfs_inode_close(ni);
                                            ntfs_inode_close(dir_ni);
                                        } else {
                                            ntfschar *old_uname = NULL;
                                            int old_uname_len = ntfs_mbstoucs(req->old_name, &old_uname);
                                            // ntfs_delete closes both ni and dir_ni
                                            r = ntfs_delete(g_vol, NULL, ni, dir_ni, old_uname, old_uname_len);
                                            free(old_uname);
                                            
                                            if (r < 0) {
                                                printf("[ntfsmagicd] ntfs_delete failed: %d, errno=%d\n", r, errno);
                                                resp.status = -errno;
                                            } else {
                                                resp.status = 0;
                                            }
                                        }
                                    }
                                } else {
                                    ntfs_inode *new_dir_ni = ntfs_inode_open(g_vol, req->new_parent_ino);
                                    ntfs_inode *old_dir_ni = ntfs_inode_open(g_vol, req->old_parent_ino);
                                    if (!new_dir_ni || !old_dir_ni) {
                                        resp.status = -errno;
                                        if (new_dir_ni) ntfs_inode_close(new_dir_ni);
                                        if (old_dir_ni) ntfs_inode_close(old_dir_ni);
                                        ntfs_inode_close(ni);
                                    } else {
                                        ntfschar *new_uname = NULL;
                                        int new_uname_len = ntfs_mbstoucs(req->new_name, &new_uname);
                                        int r = ntfs_link(ni, new_dir_ni, new_uname, new_uname_len);
                                        free(new_uname);
                                        
                                        if (r < 0) {
                                            printf("[ntfsmagicd] ntfs_link (diff dir) failed: %d, errno=%d\n", r, errno);
                                            resp.status = -errno;
                                            ntfs_inode_close(ni);
                                            ntfs_inode_close(new_dir_ni);
                                            ntfs_inode_close(old_dir_ni);
                                        } else {
                                            ntfschar *old_uname = NULL;
                                            int old_uname_len = ntfs_mbstoucs(req->old_name, &old_uname);
                                            // ntfs_delete closes both ni and old_dir_ni
                                            r = ntfs_delete(g_vol, NULL, ni, old_dir_ni, old_uname, old_uname_len);
                                            free(old_uname);
                                            
                                            ntfs_inode_close(new_dir_ni);
                                            if (r < 0) {
                                                printf("[ntfsmagicd] ntfs_delete (diff dir) failed: %d, errno=%d\n", r, errno);
                                                resp.status = -errno;
                                            } else {
                                                resp.status = 0;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                    
                    struct ntfs_msg_header resp_hdr;
                    resp_hdr.length = sizeof(resp_hdr) + sizeof(resp);
                    resp_hdr.type = NTFS_MSG_RENAME;
                    resp_hdr.request_id = hdr.request_id;
                    
                    write(client_fd, &resp_hdr, sizeof(resp_hdr));
                    write(client_fd, &resp, sizeof(resp));
                    break;
                }
                case NTFS_MSG_TRUNCATE: {
                    struct ntfs_msg_truncate_req *req = (struct ntfs_msg_truncate_req *)payload;
                    struct ntfs_msg_truncate_resp resp;
                    memset(&resp, 0, sizeof(resp));
                    
                    ntfs_inode *ni = cache_get_inode(req->ino);
                    if (!ni) {
                        resp.status = -errno;
                    } else {
                        ntfs_attr *na = ntfs_attr_open(ni, AT_DATA, NULL, 0);
                        if (!na) {
                            resp.status = -errno;
                        } else {
                            int r = ntfs_attr_truncate(na, req->size);
                            ntfs_attr_close(na);
                            if (r < 0) {
                                    resp.status = -errno;
                            } else {
                                resp.status = 0;
                            }
                        }
                    }
                    
                    struct ntfs_msg_header resp_hdr;
                    resp_hdr.length = sizeof(resp_hdr) + sizeof(resp);
                    resp_hdr.type = NTFS_MSG_TRUNCATE;
                    resp_hdr.request_id = hdr.request_id;
                    
                    write(client_fd, &resp_hdr, sizeof(resp_hdr));
                    write(client_fd, &resp, sizeof(resp));
                    break;
                }
                case NTFS_MSG_SYNC: {
                    cache_close_all();
                    
                    struct ntfs_msg_header resp_hdr;
                    int32_t status = 0;
                    resp_hdr.length = sizeof(resp_hdr) + sizeof(status);
                    resp_hdr.type = NTFS_MSG_SYNC;
                    resp_hdr.request_id = hdr.request_id;
                    
                    write(client_fd, &resp_hdr, sizeof(resp_hdr));
                    write(client_fd, &status, sizeof(status));
                    break;
                }
                default:
                    printf("[ntfsmagicd] Unknown message type: %d\n", hdr.type);
                    break;
            }
        }
        
        pthread_mutex_unlock(&g_lock);
        if (payload) free(payload);
    }
    close(client_fd);
}

int main(int argc, char **argv) {
    setbuf(stdout, NULL);
    setbuf(stderr, NULL);
    printf("[ntfsmagicd] Starting helper daemon...\n");
    unlink(NTFSMAGICD_SOCKET_PATH);
    
    int server_fd = socket(AF_UNIX, SOCK_STREAM, 0);
    if (server_fd < 0) {
        perror("socket");
        return 1;
    }
    
    struct sockaddr_un addr;
    memset(&addr, 0, sizeof(addr));
    addr.sun_family = AF_UNIX;
    strncpy(addr.sun_path, NTFSMAGICD_SOCKET_PATH, sizeof(addr.sun_path) - 1);
    
    if (bind(server_fd, (struct sockaddr *)&addr, sizeof(addr)) < 0) {
        perror("bind");
        close(server_fd);
        return 1;
    }
    
    // Allow any user to connect to the socket (since AppEx runs in user space)
    chmod(NTFSMAGICD_SOCKET_PATH, 0777);
    
    if (listen(server_fd, 5) < 0) {
        perror("listen");
        close(server_fd);
        return 1;
    }
    
    printf("[ntfsmagicd] Listening on Unix Domain Socket: %s\n", NTFSMAGICD_SOCKET_PATH);
    
    while (1) {
        int client_fd = accept(server_fd, NULL, NULL);
        if (client_fd < 0) {
            perror("accept");
            continue;
        }
        printf("[ntfsmagicd] Client connected!\n");
        handle_client(client_fd);
        printf("[ntfsmagicd] Client disconnected.\n");
    }
    
    close(server_fd);
    unlink(NTFSMAGICD_SOCKET_PATH);
    return 0;
}

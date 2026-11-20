/* sysmon_probe.c — Native cross-platform system telemetry probe for Goose sysmon.
 * Supports macOS (Mach, sysctl, libproc, getfsstat/statvfs) and Linux (/proc, statvfs).
 */

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>

#if defined(__APPLE__)
#include <libproc.h>
#include <mach/mach.h>
#include <mach/mach_host.h>
#include <mach/mach_time.h>
#include <mach/processor_info.h>
#include <sys/attr.h>
#include <sys/mount.h>
#include <sys/param.h>
#include <sys/statvfs.h>
#include <sys/sysctl.h>
#include <sys/types.h>
#include <sys/utsname.h>
#elif defined(__linux__)
#include <dirent.h>
#include <sys/statvfs.h>
#include <sys/sysinfo.h>
#include <sys/utsname.h>
#else
#include <sys/utsname.h>
#endif

typedef struct {
    uint8_t *data;
    int64_t len;
} sm_u8_slice;

typedef struct {
    int64_t *data;
    int64_t len;
} sm_i64_slice;

static int64_t write_u8_slice(sm_u8_slice out, const char *src) {
    if (!out.data || out.len <= 0 || !src) return 0;
    size_t n = strlen(src);
    if ((int64_t)n > out.len) n = (size_t)out.len;
    if (n > 0) memcpy(out.data, src, n);
    return (int64_t)n;
}

static void write_slot32(uint8_t *base, int64_t idx, const char *src) {
    uint8_t *dst = base + idx * 32;
    memset(dst, 0, 32);
    if (!src) return;
    size_t n = strlen(src);
    if (n > 31) n = 31;
    memcpy(dst, src, n);
}

int64_t probe_hostname(sm_u8_slice out) {
    char buf[128];
    memset(buf, 0, sizeof(buf));
    if (gethostname(buf, sizeof(buf) - 1) != 0 || buf[0] == '\0') {
        snprintf(buf, sizeof(buf), "localhost");
    }
    return write_u8_slice(out, buf);
}

int64_t probe_os_name(sm_u8_slice out) {
    char buf[128];
    struct utsname u;
    memset(&u, 0, sizeof(u));
    if (uname(&u) != 0) {
        return write_u8_slice(out, "POSIX");
    }
#if defined(__APPLE__)
    char prod[64];
    size_t plen = sizeof(prod);
    memset(prod, 0, sizeof(prod));
    if (sysctlbyname("kern.osproductversion", prod, &plen, NULL, 0) == 0 && prod[0] != '\0') {
        snprintf(buf, sizeof(buf), "macOS %s (%s)", prod, u.machine);
    } else {
        snprintf(buf, sizeof(buf), "%s %s (%s)", u.sysname, u.release, u.machine);
    }
#else
    snprintf(buf, sizeof(buf), "%s %s (%s)", u.sysname, u.release, u.machine);
#endif
    return write_u8_slice(out, buf);
}

int64_t probe_cpu_model(sm_u8_slice out) {
    char buf[128];
    memset(buf, 0, sizeof(buf));
#if defined(__APPLE__)
    size_t len = sizeof(buf) - 1;
    if (sysctlbyname("machdep.cpu.brand_string", buf, &len, NULL, 0) != 0 || buf[0] == '\0') {
        len = sizeof(buf) - 1;
        if (sysctlbyname("hw.model", buf, &len, NULL, 0) != 0 || buf[0] == '\0') {
            snprintf(buf, sizeof(buf), "Apple Silicon");
        }
    }
#elif defined(__linux__)
    FILE *f = fopen("/proc/cpuinfo", "r");
    if (f) {
        char line[256];
        while (fgets(line, sizeof(line), f)) {
            if (strncmp(line, "model name", 10) == 0 || strncmp(line, "Hardware", 8) == 0) {
                char *colon = strchr(line, ':');
                if (colon) {
                    colon++;
                    while (*colon == ' ' || *colon == '\t') colon++;
                    char *nl = strpbrk(colon, "\r\n");
                    if (nl) *nl = '\0';
                    snprintf(buf, sizeof(buf), "%s", colon);
                    break;
                }
            }
        }
        fclose(f);
    }
    if (buf[0] == '\0') snprintf(buf, sizeof(buf), "Linux CPU");
#else
    snprintf(buf, sizeof(buf), "Generic CPU");
#endif
    return write_u8_slice(out, buf);
}

int64_t probe_sys_meta(sm_i64_slice out) {
    if (!out.data || out.len < 8) return 0;
    memset(out.data, 0, sizeof(int64_t) * 8);

    double loads[3] = {0.0, 0.0, 0.0};
    if (getloadavg(loads, 3) < 0) {
        loads[0] = 0.0;
        loads[1] = 0.0;
        loads[2] = 0.0;
    }
    out.data[4] = (int64_t)(loads[0] * 100.0 + 0.5);
    out.data[5] = (int64_t)(loads[1] * 100.0 + 0.5);
    out.data[6] = (int64_t)(loads[2] * 100.0 + 0.5);

#if defined(__APPLE__)
    int32_t logical = 1, physical = 1;
    size_t lsz = sizeof(logical);
    if (sysctlbyname("hw.logicalcpu", &logical, &lsz, NULL, 0) != 0 || logical < 1) logical = 1;
    lsz = sizeof(physical);
    if (sysctlbyname("hw.physicalcpu", &physical, &lsz, NULL, 0) != 0 || physical < 1) physical = logical;

    struct timeval boottime;
    memset(&boottime, 0, sizeof(boottime));
    lsz = sizeof(boottime);
    int64_t uptime = 0;
    if (sysctlbyname("kern.boottime", &boottime, &lsz, NULL, 0) == 0 && boottime.tv_sec > 0) {
        time_t now = time(NULL);
        if (now > boottime.tv_sec) uptime = (int64_t)(now - boottime.tv_sec);
    }

    uint64_t memsize = 0;
    lsz = sizeof(memsize);
    if (sysctlbyname("hw.memsize", &memsize, &lsz, NULL, 0) != 0) memsize = 0;

    int pid_bytes = proc_listallpids(NULL, 0);
    int64_t nprocs = pid_bytes > 0 ? (int64_t)(pid_bytes / (int)sizeof(pid_t)) : 0;

    out.data[0] = (int64_t)logical;
    out.data[1] = (int64_t)physical;
    out.data[2] = uptime;
    out.data[3] = (int64_t)memsize;
    out.data[7] = nprocs;
#elif defined(__linux__)
    long onl = sysconf(_SC_NPROCESSORS_ONLN);
    out.data[0] = onl > 0 ? (int64_t)onl : 1;
    out.data[1] = out.data[0];

    struct sysinfo si;
    if (sysinfo(&si) == 0) {
        out.data[2] = (int64_t)si.uptime;
        out.data[3] = (int64_t)si.totalram * (int64_t)si.mem_unit;
        out.data[7] = (int64_t)si.procs;
    }
#else
    out.data[0] = 1;
    out.data[1] = 1;
#endif
    return 1;
}

int64_t probe_cpu_ticks(sm_i64_slice out) {
    if (!out.data || out.len < 4) return 0;
    int64_t max_cores = out.len / 4;
#if defined(__APPLE__)
    natural_t num_cpu = 0;
    processor_info_array_t cpu_info = NULL;
    mach_msg_type_number_t info_cnt = 0;
    kern_return_t kr = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                           &num_cpu, &cpu_info, &info_cnt);
    if (kr != KERN_SUCCESS || !cpu_info) return 0;

    processor_cpu_load_info_t load = (processor_cpu_load_info_t)cpu_info;
    int64_t count = (int64_t)num_cpu;
    if (count > max_cores) count = max_cores;
    for (int64_t i = 0; i < count; i++) {
        out.data[i * 4 + 0] = (int64_t)load[i].cpu_ticks[CPU_STATE_USER];
        out.data[i * 4 + 1] = (int64_t)load[i].cpu_ticks[CPU_STATE_SYSTEM];
        out.data[i * 4 + 2] = (int64_t)load[i].cpu_ticks[CPU_STATE_IDLE];
        out.data[i * 4 + 3] = (int64_t)load[i].cpu_ticks[CPU_STATE_NICE];
    }
    vm_deallocate(mach_task_self(), (vm_address_t)cpu_info,
                  (vm_size_t)(info_cnt * sizeof(integer_t)));
    return count;
#elif defined(__linux__)
    FILE *f = fopen("/proc/stat", "r");
    if (!f) return 0;
    char line[512];
    int64_t count = 0;
    while (fgets(line, sizeof(line), f) && count < max_cores) {
        if (strncmp(line, "cpu", 3) == 0 && isdigit((unsigned char)line[3])) {
            unsigned long long u = 0, n = 0, s = 0, id = 0, io = 0, irq = 0, sirq = 0, st = 0;
            char tag[32];
            int parsed = sscanf(line, "%31s %llu %llu %llu %llu %llu %llu %llu %llu",
                                tag, &u, &n, &s, &id, &io, &irq, &sirq, &st);
            if (parsed >= 5) {
                out.data[count * 4 + 0] = (int64_t)u;
                out.data[count * 4 + 1] = (int64_t)(s + irq + sirq + st);
                out.data[count * 4 + 2] = (int64_t)(id + io);
                out.data[count * 4 + 3] = (int64_t)n;
                count++;
            }
        }
    }
    fclose(f);
    return count;
#else
    (void)max_cores;
    return 0;
#endif
}

int64_t probe_memory(sm_i64_slice out) {
    if (!out.data || out.len < 9) return 0;
    memset(out.data, 0, sizeof(int64_t) * 9);
#if defined(__APPLE__)
    uint64_t memsize = 0;
    size_t sz = sizeof(memsize);
    if (sysctlbyname("hw.memsize", &memsize, &sz, NULL, 0) != 0) memsize = 0;

    vm_size_t ps = 0;
    if (host_page_size(mach_host_self(), &ps) != KERN_SUCCESS || ps == 0) ps = 16384;

    vm_statistics64_data_t vm;
    memset(&vm, 0, sizeof(vm));
    mach_msg_type_number_t cnt = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&vm, &cnt) == KERN_SUCCESS) {
        int64_t internal_sub = (int64_t)vm.internal_page_count - (int64_t)vm.purgeable_count;
        if (internal_sub < 0) internal_sub = 0;
        int64_t app_b = internal_sub * (int64_t)ps;
        int64_t wired_b = (int64_t)vm.wire_count * (int64_t)ps;
        int64_t comp_b = (int64_t)vm.compressor_page_count * (int64_t)ps;
        int64_t cached_b = ((int64_t)vm.external_page_count + (int64_t)vm.purgeable_count) * (int64_t)ps;
        int64_t used_b = app_b + wired_b + comp_b;
        if ((int64_t)memsize > 0 && used_b > (int64_t)memsize) used_b = (int64_t)memsize;
        int64_t free_b = (int64_t)memsize > used_b ? (int64_t)memsize - used_b : 0;

        out.data[0] = (int64_t)memsize;
        out.data[1] = used_b;
        out.data[2] = app_b;
        out.data[3] = wired_b;
        out.data[4] = comp_b;
        out.data[5] = cached_b;
        out.data[6] = free_b;
    } else {
        out.data[0] = (int64_t)memsize;
    }

    struct xsw_usage xsw;
    memset(&xsw, 0, sizeof(xsw));
    sz = sizeof(xsw);
    if (sysctlbyname("vm.swapusage", &xsw, &sz, NULL, 0) == 0) {
        out.data[7] = (int64_t)xsw.xsu_total;
        out.data[8] = (int64_t)xsw.xsu_used;
    }
    return 1;
#elif defined(__linux__)
    FILE *f = fopen("/proc/meminfo", "r");
    if (!f) return 0;
    int64_t mem_tot = 0, mem_avail = -1, mem_free = 0, buffers = 0, cached = 0, active = 0;
    int64_t swap_tot = 0, swap_free = 0;
    char line[256];
    while (fgets(line, sizeof(line), f)) {
        long long v = 0;
        if (sscanf(line, "MemTotal: %lld kB", &v) == 1) mem_tot = (int64_t)v * 1024;
        else if (sscanf(line, "MemAvailable: %lld kB", &v) == 1) mem_avail = (int64_t)v * 1024;
        else if (sscanf(line, "MemFree: %lld kB", &v) == 1) mem_free = (int64_t)v * 1024;
        else if (sscanf(line, "Buffers: %lld kB", &v) == 1) buffers = (int64_t)v * 1024;
        else if (sscanf(line, "Cached: %lld kB", &v) == 1) cached = (int64_t)v * 1024;
        else if (sscanf(line, "Active: %lld kB", &v) == 1) active = (int64_t)v * 1024;
        else if (sscanf(line, "SwapTotal: %lld kB", &v) == 1) swap_tot = (int64_t)v * 1024;
        else if (sscanf(line, "SwapFree: %lld kB", &v) == 1) swap_free = (int64_t)v * 1024;
    }
    fclose(f);
    if (mem_avail < 0) mem_avail = mem_free + buffers + cached;
    int64_t used_b = mem_tot > mem_avail ? mem_tot - mem_avail : 0;
    out.data[0] = mem_tot;
    out.data[1] = used_b;
    out.data[2] = active > 0 ? active : used_b;
    out.data[3] = 0;
    out.data[4] = 0;
    out.data[5] = buffers + cached;
    out.data[6] = mem_avail;
    out.data[7] = swap_tot;
    out.data[8] = swap_tot > swap_free ? swap_tot - swap_free : 0;
    return 1;
#else
    return 0;
#endif
}

int64_t probe_disks(sm_u8_slice mounts_out, sm_i64_slice stats_out, int64_t max_disks) {
    if (!mounts_out.data || !stats_out.data || max_disks <= 0) return 0;
    if (mounts_out.len < max_disks * 32 || stats_out.len < max_disks * 3) return 0;

    int64_t n = 0;
#if defined(__APPLE__)
    struct statvfs sv;
    const char *root_probe = (statvfs("/System/Volumes/Data", &sv) == 0) ? "/System/Volumes/Data" : "/";
    if (statvfs(root_probe, &sv) == 0 && sv.f_blocks > 0) {
        uint64_t fsz = sv.f_frsize ? sv.f_frsize : sv.f_bsize;
        int64_t tot = (int64_t)((uint64_t)sv.f_blocks * fsz);
        int64_t avail = (int64_t)((uint64_t)sv.f_bavail * fsz);
        int64_t used = tot > avail ? tot - avail : 0;
        write_slot32(mounts_out.data, n, "/");
        stats_out.data[n * 3 + 0] = tot;
        stats_out.data[n * 3 + 1] = used;
        stats_out.data[n * 3 + 2] = avail;
        n++;
    }

    int fs_cnt = getfsstat(NULL, 0, MNT_NOWAIT);
    if (fs_cnt > 0 && n < max_disks) {
        struct statfs *fs = (struct statfs *)calloc((size_t)fs_cnt, sizeof(struct statfs));
        if (fs) {
            int got = getfsstat(fs, fs_cnt * (int)sizeof(struct statfs), MNT_NOWAIT);
            for (int i = 0; i < got && n < max_disks; i++) {
                const char *mp = fs[i].f_mntonname;
                const char *ft = fs[i].f_fstypename;
                if (!mp || strcmp(mp, "/") == 0) continue;
                if (strncmp(mp, "/dev", 4) == 0) continue;
                if (strncmp(mp, "/System/Volumes/", 16) == 0) continue;
                if (strcmp(mp, "/Volumes/Recovery") == 0) continue;
                if (strcmp(ft, "devfs") == 0 || strcmp(ft, "autofs") == 0) continue;
                if (strncmp(fs[i].f_mntfromname, "map ", 4) == 0) continue;
                if (fs[i].f_blocks == 0) continue;
                struct statvfs s2;
                if (statvfs(mp, &s2) == 0 && s2.f_blocks > 0) {
                    uint64_t fsz2 = s2.f_frsize ? s2.f_frsize : s2.f_bsize;
                    int64_t tot2 = (int64_t)((uint64_t)s2.f_blocks * fsz2);
                    int64_t avail2 = (int64_t)((uint64_t)s2.f_bavail * fsz2);
                    int64_t used2 = (s2.f_blocks > s2.f_bfree)
                                        ? (int64_t)((uint64_t)(s2.f_blocks - s2.f_bfree) * fsz2)
                                        : 0;
                    struct attrlist al;
                    memset(&al, 0, sizeof(al));
                    al.bitmapcount = ATTR_BIT_MAP_COUNT;
                    al.volattr = ATTR_VOL_INFO | ATTR_VOL_SPACEUSED;
                    typedef struct __attribute__((aligned(4), packed)) {
                        uint32_t length;
                        off_t spaceused;
                    } sm_vol_used_attr;
                    sm_vol_used_attr vbuf;
                    memset(&vbuf, 0, sizeof(vbuf));
                    if (getattrlist(mp, &al, &vbuf, sizeof(vbuf), 0) == 0 &&
                        vbuf.length >= sizeof(vbuf) && vbuf.spaceused >= 0 &&
                        (int64_t)vbuf.spaceused <= tot2) {
                        used2 = (int64_t)vbuf.spaceused;
                    }
                    write_slot32(mounts_out.data, n, mp);
                    stats_out.data[n * 3 + 0] = tot2;
                    stats_out.data[n * 3 + 1] = used2;
                    stats_out.data[n * 3 + 2] = avail2;
                    n++;
                }
            }
            free(fs);
        }
    }
#elif defined(__linux__)
    FILE *f = fopen("/proc/mounts", "r");
    if (f) {
        char dev[256], mp[256], fst[64];
        char line[1024];
        while (fgets(line, sizeof(line), f) && n < max_disks) {
            if (sscanf(line, "%255s %255s %63s", dev, mp, fst) == 3) {
                if (strcmp(fst, "proc") == 0 || strcmp(fst, "sysfs") == 0 ||
                    strcmp(fst, "tmpfs") == 0 || strcmp(fst, "devtmpfs") == 0 ||
                    strcmp(fst, "devpts") == 0 || strcmp(fst, "cgroup2") == 0 ||
                    strcmp(fst, "squashfs") == 0 || strncmp(mp, "/sys", 4) == 0 ||
                    strncmp(mp, "/proc", 5) == 0 || strncmp(mp, "/dev", 4) == 0) {
                    continue;
                }
                struct statvfs sv;
                if (statvfs(mp, &sv) == 0 && sv.f_blocks > 0) {
                    uint64_t fsz = sv.f_frsize ? sv.f_frsize : sv.f_bsize;
                    int64_t tot = (int64_t)((uint64_t)sv.f_blocks * fsz);
                    int64_t avail = (int64_t)((uint64_t)sv.f_bavail * fsz);
                    int64_t used = tot > avail ? tot - avail : 0;
                    write_slot32(mounts_out.data, n, mp);
                    stats_out.data[n * 3 + 0] = tot;
                    stats_out.data[n * 3 + 1] = used;
                    stats_out.data[n * 3 + 2] = avail;
                    n++;
                }
            }
        }
        fclose(f);
    }
#endif
    return n;
}

typedef struct {
    int64_t pid;
    int64_t rss;
    int64_t threads;
    int64_t cpu_ms;
    char name[32];
} sm_proc_rec;

static int cmp_proc_mem(const void *a, const void *b) {
    const sm_proc_rec *pa = (const sm_proc_rec *)a;
    const sm_proc_rec *pb = (const sm_proc_rec *)b;
    if (pb->rss > pa->rss) return 1;
    if (pb->rss < pa->rss) return -1;
    return (pa->pid > pb->pid) ? 1 : ((pa->pid < pb->pid) ? -1 : 0);
}

static int cmp_proc_cpu(const void *a, const void *b) {
    const sm_proc_rec *pa = (const sm_proc_rec *)a;
    const sm_proc_rec *pb = (const sm_proc_rec *)b;
    if (pb->cpu_ms > pa->cpu_ms) return 1;
    if (pb->cpu_ms < pa->cpu_ms) return -1;
    return cmp_proc_mem(a, b);
}

static int cmp_proc_pid(const void *a, const void *b) {
    const sm_proc_rec *pa = (const sm_proc_rec *)a;
    const sm_proc_rec *pb = (const sm_proc_rec *)b;
    return (pa->pid > pb->pid) ? 1 : ((pa->pid < pb->pid) ? -1 : 0);
}

int64_t probe_top_procs(sm_u8_slice names_out, sm_i64_slice stats_out,
                        int64_t max_procs, int64_t sort_mode) {
    if (!names_out.data || !stats_out.data || max_procs <= 0) return 0;
    if (names_out.len < max_procs * 32 || stats_out.len < max_procs * 4) return 0;

    int64_t cap = 256;
    int64_t count = 0;
    sm_proc_rec *recs = NULL;

#if defined(__APPLE__)
    mach_timebase_info_data_t tb = {1, 1};
    mach_timebase_info(&tb);
    if (tb.denom == 0) tb.denom = 1;

    int est = proc_listallpids(NULL, 0);
    if (est <= 0) return 0;
    int pid_cap = (est / (int)sizeof(pid_t)) * 2 + 64;
    pid_t *pids = (pid_t *)calloc((size_t)pid_cap, sizeof(pid_t));
    if (!pids) return 0;

    int bytes_got = proc_listallpids(pids, pid_cap * (int)sizeof(pid_t));
    int n_pids = bytes_got > 0 ? bytes_got / (int)sizeof(pid_t) : 0;
    if (n_pids > cap) cap = n_pids;
    recs = (sm_proc_rec *)calloc((size_t)cap, sizeof(sm_proc_rec));
    if (!recs) {
        free(pids);
        return 0;
    }

    for (int i = 0; i < n_pids; i++) {
        pid_t pid = pids[i];
        if (pid <= 0) continue;
        struct proc_taskinfo ti;
        memset(&ti, 0, sizeof(ti));
        if (proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, (int)sizeof(ti)) <= 0) continue;
        sm_proc_rec *r = &recs[count];
        r->pid = (int64_t)pid;
        r->rss = (int64_t)ti.pti_resident_size;
        r->threads = (int64_t)ti.pti_threadnum;
        uint64_t ticks = (uint64_t)ti.pti_total_user + (uint64_t)ti.pti_total_system;
        uint64_t ns = (ticks / tb.denom) * tb.numer + ((ticks % tb.denom) * tb.numer) / tb.denom;
        r->cpu_ms = (int64_t)(ns / 1000000ULL);
        char pname[64];
        memset(pname, 0, sizeof(pname));
        int pn = proc_name(pid, pname, (uint32_t)(sizeof(pname) - 1));
        if (pn <= 0 || pname[0] == '\0') {
            snprintf(pname, sizeof(pname), "pid-%d", (int)pid);
        }
        memset(r->name, 0, sizeof(r->name));
        strncpy(r->name, pname, 31);
        count++;
    }
    free(pids);
#elif defined(__linux__)
    DIR *d = opendir("/proc");
    if (!d) return 0;
    recs = (sm_proc_rec *)calloc((size_t)cap, sizeof(sm_proc_rec));
    if (!recs) {
        closedir(d);
        return 0;
    }
    long ps = sysconf(_SC_PAGESIZE);
    long hz = sysconf(_SC_CLK_TCK);
    if (ps <= 0) ps = 4096;
    if (hz <= 0) hz = 100;

    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (!isdigit((unsigned char)de->d_name[0])) continue;
        long pid = strtol(de->d_name, NULL, 10);
        if (pid <= 0) continue;

        char spath[64];
        snprintf(spath, sizeof(spath), "/proc/%ld/stat", pid);
        FILE *sf = fopen(spath, "r");
        if (!sf) continue;
        char line[1024];
        if (!fgets(line, sizeof(line), sf)) {
            fclose(sf);
            continue;
        }
        fclose(sf);

        char *lp = strchr(line, '(');
        char *rp = strrchr(line, ')');
        if (!lp || !rp || rp <= lp) continue;

        if (count >= cap) {
            cap *= 2;
            sm_proc_rec *nr = (sm_proc_rec *)realloc(recs, (size_t)cap * sizeof(sm_proc_rec));
            if (!nr) break;
            recs = nr;
        }
        sm_proc_rec *r = &recs[count];
        memset(r, 0, sizeof(*r));
        r->pid = (int64_t)pid;
        size_t nlen = (size_t)(rp - lp - 1);
        if (nlen > 31) nlen = 31;
        memcpy(r->name, lp + 1, nlen);

        char state = '?';
        unsigned long long ut = 0, st = 0;
        long thr = 0, rss_p = 0;
        long long dummy = 0;
        unsigned long long udummy = 0;
        int got = sscanf(rp + 2,
                         "%c %lld %lld %lld %lld %lld %llu %llu %llu %llu %llu %llu %llu %lld %lld %lld %lld %ld %lld %llu %llu %ld",
                         &state, &dummy, &dummy, &dummy, &dummy, &dummy, &udummy, &udummy, &udummy,
                         &udummy, &udummy, &ut, &st, &dummy, &dummy, &dummy, &dummy, &thr, &dummy,
                         &udummy, &udummy, &rss_p);
        if (got >= 22) {
            r->threads = (int64_t)thr;
            r->rss = (int64_t)rss_p * (int64_t)ps;
            r->cpu_ms = (int64_t)(((ut + st) * 1000ULL) / (unsigned long long)hz);
            count++;
        }
    }
    closedir(d);
#endif

    if (!recs || count == 0) {
        free(recs);
        return 0;
    }

    if (sort_mode == 1) qsort(recs, (size_t)count, sizeof(sm_proc_rec), cmp_proc_cpu);
    else if (sort_mode == 2) qsort(recs, (size_t)count, sizeof(sm_proc_rec), cmp_proc_pid);
    else qsort(recs, (size_t)count, sizeof(sm_proc_rec), cmp_proc_mem);

    int64_t out_n = count < max_procs ? count : max_procs;
    for (int64_t i = 0; i < out_n; i++) {
        write_slot32(names_out.data, i, recs[i].name);
        stats_out.data[i * 4 + 0] = recs[i].pid;
        stats_out.data[i * 4 + 1] = recs[i].rss;
        stats_out.data[i * 4 + 2] = recs[i].threads;
        stats_out.data[i * 4 + 3] = recs[i].cpu_ms;
    }

    free(recs);
    return out_n;
}

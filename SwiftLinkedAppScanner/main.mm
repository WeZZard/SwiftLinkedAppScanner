//
//  main.m
//  SwiftLinkedAppScanner
//
//  Created by WeZZard on 11/4/21.
//

#include <sys/types.h>
#include <sys/uio.h>
#include <sys/stat.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <fcntl.h>
#include <os/overflow.h>
#include <mach-o/fat.h>
#include <mach-o/dyld.h>
#include <mach-o/loader.h>
#include <libkern/OSByteOrder.h>

#include <algorithm>
#include <vector>
using namespace std;

#include <Foundation/Foundation.h>

#pragma clang diagnostic ignored "-Wgcc-compat"

#ifndef CPU_TYPE_ARM64
#   define CPU_TYPE_ARM64  ((cpu_type_t) (CPU_TYPE_ARM | CPU_ARCH_ABI64))
#endif

static int Verbose = 0;

#ifdef __OPTIMIZE__
#define INLINE  __attribute__((always_inline))
#else
#define INLINE
#endif

//
// This abstraction layer is for use with file formats that have 64-bit/32-bit and Big-Endian/Little-Endian variants
//
// For example: to make a utility that handles 32-bit little enidan files use:  Pointer32<LittleEndian>
//
//
//    get16()      read a 16-bit number from an E endian struct
//    set16()      write a 16-bit number to an E endian struct
//    get32()      read a 32-bit number from an E endian struct
//    set32()      write a 32-bit number to an E endian struct
//    get64()      read a 64-bit number from an E endian struct
//    set64()      write a 64-bit number to an E endian struct
//
//    getBits()    read a bit field from an E endian struct (bitCount=number of bits in field, firstBit=bit index of field)
//    setBits()    write a bit field to an E endian struct (bitCount=number of bits in field, firstBit=bit index of field)
//
//    getBitsRaw()  read a bit field from a struct with native endianness
//    setBitsRaw()  write a bit field from a struct with native endianness
//

class BigEndian
{
public:
  static uint16_t  get16(const uint16_t& from)        INLINE { return OSReadBigInt16(&from, 0); }
  static void    set16(uint16_t& into, uint16_t value)  INLINE { OSWriteBigInt16(&into, 0, value); }
  
  static uint32_t  get32(const uint32_t& from)        INLINE { return OSReadBigInt32(&from, 0); }
  static void    set32(uint32_t& into, uint32_t value)  INLINE { OSWriteBigInt32(&into, 0, value); }
  
  static uint64_t get64(const uint64_t& from)        INLINE { return OSReadBigInt64(&from, 0); }
  static void    set64(uint64_t& into, uint64_t value)  INLINE { OSWriteBigInt64(&into, 0, value); }
  
  static uint32_t  getBits(const uint32_t& from,
                           uint8_t firstBit, uint8_t bitCount)  INLINE { return getBitsRaw(get32(from), firstBit, bitCount); }
  static void    setBits(uint32_t& into, uint32_t value,
                         uint8_t firstBit, uint8_t bitCount)  INLINE { uint32_t temp = get32(into); setBitsRaw(temp, value, firstBit, bitCount); set32(into, temp); }
  
  static uint32_t  getBitsRaw(const uint32_t& from,
                              uint8_t firstBit, uint8_t bitCount)  INLINE { return ((from >> (32-firstBit-bitCount)) & ((1<<bitCount)-1)); }
  static void    setBitsRaw(uint32_t& into, uint32_t value,
                            uint8_t firstBit, uint8_t bitCount)  INLINE { uint32_t temp = into;
    const uint32_t mask = ((1<<bitCount)-1);
    temp &= ~(mask << (32-firstBit-bitCount));
    temp |= ((value & mask) << (32-firstBit-bitCount));
    into = temp; }
  enum { little_endian = 0 };
};


class LittleEndian
{
public:
  static uint16_t  get16(const uint16_t& from)        INLINE { return OSReadLittleInt16(&from, 0); }
  static void    set16(uint16_t& into, uint16_t value)  INLINE { OSWriteLittleInt16(&into, 0, value); }
  
  static uint32_t  get32(const uint32_t& from)        INLINE { return OSReadLittleInt32(&from, 0); }
  static void    set32(uint32_t& into, uint32_t value)  INLINE { OSWriteLittleInt32(&into, 0, value); }
  
  static uint64_t get64(const uint64_t& from)        INLINE { return OSReadLittleInt64(&from, 0); }
  static void    set64(uint64_t& into, uint64_t value)  INLINE { OSWriteLittleInt64(&into, 0, value); }
  
  static uint32_t  getBits(const uint32_t& from,
                           uint8_t firstBit, uint8_t bitCount)  INLINE { return getBitsRaw(get32(from), firstBit, bitCount); }
  static void    setBits(uint32_t& into, uint32_t value,
                         uint8_t firstBit, uint8_t bitCount)  INLINE { uint32_t temp = get32(into); setBitsRaw(temp, value, firstBit, bitCount); set32(into, temp); }
  
  static uint32_t  getBitsRaw(const uint32_t& from,
                              uint8_t firstBit, uint8_t bitCount)  INLINE { return ((from >> firstBit) & ((1<<bitCount)-1)); }
  static void    setBitsRaw(uint32_t& into, uint32_t value,
                            uint8_t firstBit, uint8_t bitCount)  INLINE {  uint32_t temp = into;
    const uint32_t mask = ((1<<bitCount)-1);
    temp &= ~(mask << firstBit);
    temp |= ((value & mask) << firstBit);
    into = temp; }
  enum { little_endian = 1 };
};

#if __BIG_ENDIAN__
typedef BigEndian CurrentEndian;
typedef LittleEndian OtherEndian;
#elif __LITTLE_ENDIAN__
typedef LittleEndian CurrentEndian;
typedef BigEndian OtherEndian;
#else
#error unknown endianness
#endif


template <typename _E>
class Pointer32
{
public:
  typedef uint32_t  uint_t;
  typedef int32_t    sint_t;
  typedef _E      E;
  
  static uint64_t  getP(const uint_t& from)        INLINE { return _E::get32(from); }
  static void    setP(uint_t& into, uint64_t value)    INLINE { _E::set32(into, value); }
};


template <typename _E>
class Pointer64
{
public:
  typedef uint64_t  uint_t;
  typedef int64_t    sint_t;
  typedef _E      E;
  
  static uint64_t  getP(const uint_t& from)        INLINE { return _E::get64(from); }
  static void    setP(uint_t& into, uint64_t value)    INLINE { _E::set64(into, value); }
};


//
// mach-o file header
//
template <typename P> struct macho_header_content {};
template <> struct macho_header_content<Pointer32<BigEndian> >    { mach_header    fields; };
template <> struct macho_header_content<Pointer64<BigEndian> >    { mach_header_64  fields; };
template <> struct macho_header_content<Pointer32<LittleEndian> > { mach_header    fields; };
template <> struct macho_header_content<Pointer64<LittleEndian> > { mach_header_64  fields; };

template <typename P>
class macho_header {
public:
  uint32_t    magic() const          INLINE { return E::get32(header.fields.magic); }
  void      set_magic(uint32_t value)    INLINE { E::set32(header.fields.magic, value); }
  
  uint32_t    cputype() const          INLINE { return E::get32(header.fields.cputype); }
  void      set_cputype(uint32_t value)    INLINE { E::set32((uint32_t&)header.fields.cputype, value); }
  
  uint32_t    cpusubtype() const        INLINE { return E::get32(header.fields.cpusubtype); }
  void      set_cpusubtype(uint32_t value)  INLINE { E::set32((uint32_t&)header.fields.cpusubtype, value); }
  
  uint32_t    filetype() const        INLINE { return E::get32(header.fields.filetype); }
  void      set_filetype(uint32_t value)  INLINE { E::set32(header.fields.filetype, value); }
  
  uint32_t    ncmds() const          INLINE { return E::get32(header.fields.ncmds); }
  void      set_ncmds(uint32_t value)    INLINE { E::set32(header.fields.ncmds, value); }
  
  uint32_t    sizeofcmds() const        INLINE { return E::get32(header.fields.sizeofcmds); }
  void      set_sizeofcmds(uint32_t value)  INLINE { E::set32(header.fields.sizeofcmds, value); }
  
  uint32_t    flags() const          INLINE { return E::get32(header.fields.flags); }
  void      set_flags(uint32_t value)    INLINE { E::set32(header.fields.flags, value); }
  
  uint32_t    reserved() const        INLINE { return E::get32(header.fields.reserved); }
  void      set_reserved(uint32_t value)  INLINE { E::set32(header.fields.reserved, value); }
  
  typedef typename P::E    E;
private:
  macho_header_content<P>  header;
};


//
// mach-o load command
//
template <typename P>
class macho_load_command {
public:
  uint32_t    cmd() const            INLINE { return E::get32(command.cmd); }
  void      set_cmd(uint32_t value)      INLINE { E::set32(command.cmd, value); }
  
  uint32_t    cmdsize() const          INLINE { return E::get32(command.cmdsize); }
  void      set_cmdsize(uint32_t value)    INLINE { E::set32(command.cmdsize, value); }
  
  typedef typename P::E    E;
private:
  load_command  command;
};


//
// mach-o uuid load command
//
template <typename P>
class macho_uuid_command {
public:
  uint32_t    cmd() const                INLINE { return E::get32(fields.cmd); }
  void      set_cmd(uint32_t value)          INLINE { E::set32(fields.cmd, value); }
  
  uint32_t    cmdsize() const              INLINE { return E::get32(fields.cmdsize); }
  void      set_cmdsize(uint32_t value)        INLINE { E::set32(fields.cmdsize, value); }
  
  const uint8_t*  uuid() const              INLINE { return fields.uuid; }
  void      set_uuid(uint8_t value[16])        INLINE { memcpy(&fields.uuid, value, 16); }
  
  typedef typename P::E    E;
private:
  uuid_command  fields;
};


//
// mach-o dylib load command
//
template <typename P>
class macho_dylib_command {
public:
  uint32_t  cmd() const             INLINE { return E::get32(fields.cmd); }
  void      set_cmd(uint32_t value) INLINE { E::set32(fields.cmd, value); }
  
  uint32_t  cmdsize() const             INLINE { return E::get32(fields.cmdsize); }
  void      set_cmdsize(uint32_t value) INLINE { E::set32(fields.cmdsize, value); }
  
  uint32_t  name_offset() const             INLINE { return E::get32(fields.dylib.name.offset); }
  void      set_name_offset(uint32_t value) INLINE { E::set32(fields.dylib.name.offset, value);  }
  
  uint32_t  timestamp() const             INLINE { return E::get32(fields.dylib.timestamp); }
  void      set_timestamp(uint32_t value) INLINE { E::set32(fields.dylib.timestamp, value); }
  
  uint32_t  current_version() const             INLINE { return E::get32(fields.dylib.current_version); }
  void      set_current_version(uint32_t value) INLINE { E::set32(fields.dylib.current_version, value); }
  
  uint32_t  compatibility_version() const             INLINE { return E::get32(fields.dylib.compatibility_version); }
  void      set_compatibility_version(uint32_t value) INLINE { E::set32(fields.dylib.compatibility_version, value); }
  
  const char*    name() const INLINE { return (const char*)&fields + name_offset(); }
  void      set_name_offset() INLINE { set_name_offset(sizeof(fields)); }
  
  typedef typename P::E    E;
private:
  dylib_command  fields;
};


void log_vn(int verbosity, const char *msg, va_list args) __attribute__((format(printf, 2, 0))) {
  if (verbosity <= Verbose) {
    char *msg2;
    asprintf(&msg2, "%s\n", msg);
    vfprintf(stdout, msg2, args);
    free(msg2);
  }
}

int log_v(const char *msg, ...) __attribute__((format(printf, 1, 2))) {
  va_list args;
  va_start(args, msg);
  log_vn(1, msg, args);
  return -1;
}

int log_vv(const char *msg, ...) __attribute__((format(printf, 1, 2))) {
  va_list args;
  va_start(args, msg);
  log_vn(2, msg, args);
  return -1;
}


ssize_t pread_all(int fd, void *buf, size_t count, off_t offset) {
  size_t total = 0;
  while (total < count) {
    ssize_t readed = pread(fd, (void *)((char *)buf+total),
                           count-total, offset+total);
    if (readed > 0) total += readed;     // got data
    else if (readed == 0) return total;  // EOF: done
    else if (readed == -1  &&  errno != EINTR) return -1;
    // error but not EINTR: fail
  }
  
  return total;
}


template <typename T>
int parse_macho(int fd, off_t offset, off_t size) {
  ssize_t readed;
  
  macho_header<T> mh;
  if (size < sizeof(mh)) return log_vv("file is too small");
  readed = pread_all(fd, &mh, sizeof(mh), offset);
  if (readed != sizeof(mh)) return log_vv("pread failed");
  
  uint32_t sizeofcmds = mh.sizeofcmds();
  size -= sizeof(mh);
  offset += sizeof(mh);
  if (size < sizeofcmds) return log_vv("file is badly formed");
  
  uint8_t *cmdp = (uint8_t *)malloc(sizeofcmds);
  if (!cmdp) return log_vv("malloc(sizeofcmds) failed");
  
  readed = pread_all(fd, cmdp, sizeofcmds, offset);
  
  NSMutableArray<NSString *> * swiftLibs = [NSMutableArray new];
  
  if (readed == sizeofcmds) {
    uint8_t *cmds = cmdp;
    for (uint32_t c = 0; c < mh.ncmds(); c++) {
      macho_load_command<T> *cmd;
      if (size < sizeof(*cmd)) return log_vv("file is badly formed");
      cmd = (macho_load_command<T>*) cmds;
      if (size < cmd->cmdsize()) return log_vv("file is badly formed");
      cmds += cmd->cmdsize();
      size -= cmd->cmdsize();
      
      if ((cmd->cmd() == LC_LOAD_DYLIB  ||
           cmd->cmd() == LC_LOAD_WEAK_DYLIB  ||
           cmd->cmd() == LC_LAZY_LOAD_DYLIB))
      {
        macho_dylib_command<T>* dylib = (macho_dylib_command<T>*)cmd;
        if (dylib->cmdsize() < dylib->name_offset()) continue;
        char *name = (char *)dylib + dylib->name_offset();
        size_t name_len =
        strnlen(name, dylib->cmdsize() - dylib->name_offset());
        log_vv("  loads %.*s", (int)name_len, name);
        
        NSString * nameString = [NSString stringWithCString: name encoding: NSUTF8StringEncoding];
        if ([nameString containsString: @"libswift"]) {
          [swiftLibs addObject: nameString];
        }
      }
    }
  }
  
  if ([swiftLibs count] > 0) {
    char filePath[PATH_MAX];
    fcntl(fd, F_GETPATH, filePath);
    fprintf(stdout, "%s\n", filePath);
    [swiftLibs enumerateObjectsUsingBlock:^(NSString * name, NSUInteger idx, BOOL * stop) {
      fprintf(stdout, "\tLinked Swift library: %s\n", [name UTF8String]);
    }];
  }
  
  free(cmdp);
  
  return 0;
}


int parse_macho(int fd, off_t offset, off_t size) {
  uint32_t magic;
  if (size < sizeof(magic)) return log_vv("file is too small");
  ssize_t readed = pread_all(fd, &magic, sizeof(magic), offset);
  if (readed != sizeof(magic)) return log_vv("pread failed");
  
  switch (magic) {
    case MH_MAGIC_64:
      return parse_macho<Pointer64<CurrentEndian>>(fd, offset, size);
    case MH_MAGIC:
      return parse_macho<Pointer32<CurrentEndian>>(fd, offset, size);
    case MH_CIGAM_64:
      return parse_macho<Pointer64<OtherEndian>>(fd, offset, size);
    case MH_CIGAM:
      return parse_macho<Pointer32<OtherEndian>>(fd, offset, size);
    default:
      return log_vv("file is not mach-o");
  }
}


int parse_fat(int fd, off_t fsize, char *buffer, size_t size) {
  uint32_t magic;
  
  if (size < sizeof(magic)) {
    return log_vv("file is too small");
  }
  
  magic = *(uint32_t *)buffer;
  if (magic == FAT_MAGIC || magic == FAT_CIGAM) {
    struct fat_header *fh;
    uint32_t fat_magic, fat_nfat_arch;
    struct fat_arch *archs;
    uint32_t i;
    
    if (size < sizeof(struct fat_header)) {
      return log_vv("file is too small");
    }
    
    fh = (struct fat_header *)buffer;
    fat_magic = OSSwapBigToHostInt32(fh->magic);
    fat_nfat_arch = OSSwapBigToHostInt32(fh->nfat_arch);
    
    size_t fat_arch_size;
    // fat_nfat_arch * sizeof(struct fat_arch) + sizeof(struct fat_header)
    if (os_mul_and_add_overflow(fat_nfat_arch, sizeof(struct fat_arch),
                                sizeof(struct fat_header), &fat_arch_size))
    {
      return log_vv("too many fat archs\n");
    }
    if (size < fat_arch_size) {
      return log_vv("file is too small");
    }
    
    archs = (struct fat_arch *)(buffer + sizeof(struct fat_header));
    
    /* Special case hidden CPU_TYPE_ARM64 */
    size_t fat_arch_plus_one_size;
    if (os_add_overflow(fat_arch_size, sizeof(struct fat_arch),
                        &fat_arch_plus_one_size))
    {
      return log_vv("too many fat archs\n");
    }
    if (size >= fat_arch_plus_one_size) {
      if (fat_nfat_arch > 0
          && OSSwapBigToHostInt32(archs[fat_nfat_arch].cputype) == CPU_TYPE_ARM64) {
        fat_nfat_arch++;
      }
    }
    /* End special case hidden CPU_TYPE_ARM64 */
    
    for (i=0; i < fat_nfat_arch; i++) {
      int ret;
      uint32_t arch_cputype, arch_cpusubtype, arch_offset, arch_size, arch_align;
      
      arch_cputype = OSSwapBigToHostInt32(archs[i].cputype);
      arch_cpusubtype = OSSwapBigToHostInt32(archs[i].cpusubtype);
      arch_offset = OSSwapBigToHostInt32(archs[i].offset);
      arch_size = OSSwapBigToHostInt32(archs[i].size);
      arch_align = OSSwapBigToHostInt32(archs[i].align);
      
      /* Check that slice data is after all fat headers and archs */
      if (arch_offset < fat_arch_size) {
        return log_vv("file is badly formed");
      }
      
      /* Check that the slice ends before the file does */
      if (arch_offset > fsize) {
        return log_vv("file is badly formed");
      }
      
      if (arch_size > fsize) {
        return log_vv("file is badly formed");
      }
      
      if (arch_offset > (fsize - arch_size)) {
        return log_vv("file is badly formed");
      }
      
      ret = parse_macho(fd, arch_offset, arch_size);
      if (ret != 0) {
        return ret;
      }
    }
    return 0;
  } else {
    /* Not a fat file */
    return parse_macho(fd, 0, fsize);
  }
}


void process(NSString *path) {
  log_vv("Scanning %s...", path.fileSystemRepresentation);
  
  int fd = open(path.fileSystemRepresentation, O_RDONLY);
  if (fd < 0) log_vv("%s: open failed: %s",
                     path.fileSystemRepresentation, strerror(errno));
  
  struct stat st;
  if (fstat(fd, &st) < 0) {
    log_vv("%s: stat failed: %s",
           path.fileSystemRepresentation, strerror(errno));
  } else {
    const int len = 4096;
    char buf[len];
    ssize_t readed = pread_all(fd, buf, len, 0);
    if (readed != len) {
      log_vv("%s: pread failed: %s",
             path.fileSystemRepresentation, strerror(errno));
    } else {
      parse_fat(fd, st.st_size, buf, len);
    }
  }
  close(fd);
}

void visitFile(NSString * path) {
  BOOL isPathDirectory = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath: path isDirectory: &isPathDirectory]) {
    abort();
  }
  if (isPathDirectory) {
    abort();
  }
  
  process(path);
}

void visitPath(NSString * path) {
  BOOL isPathDirectory = NO;
  if (![[NSFileManager defaultManager] fileExistsAtPath: path isDirectory: &isPathDirectory]) {
    return;
  }
  if (!isPathDirectory) {
    visitFile(path);
    return;
  }
  
  NSArray<NSString *> * contents = [[NSFileManager defaultManager] contentsOfDirectoryAtPath: path error: nil];
  
  [contents enumerateObjectsUsingBlock:^(NSString * subpath, NSUInteger idx, BOOL * _Nonnull stop) {
    visitPath([path stringByAppendingPathComponent: subpath]);
  }];
}

int main(int argc, const char *argv[]) {
  @autoreleasepool {
    NSString * rootPath = nil;
    
    for (int i = 1; i < argc; i++) {
      if (0 == strcmp(argv[i], "--path")) {
        rootPath = [NSString stringWithUTF8String:argv[++i]];
      }
    }
    
    if (rootPath) {
      visitPath(rootPath);
    }
    
  }
  exit(0);
}

<?php
// How much of a file the kernel's page cache holds, like util-linux's `fincore` (the lab's images do not ship it): the file is mapped
// and mincore(2) says which of its pages are resident. Mapping a file reads nothing, so the answer is the cache's state, not a
// state this program caused.
//
//   php -d ffi.enable=1 fincore.php <file>      prints `fincore: resident_bytes=<n> size_bytes=<n> pages=<n> resident_pages=<n>`
//
// Why FFI: PHP has no mincore(), and the images' util-linux has no fincore.

$path = $argv[1] ?? '';
if ($path === '' || !is_file($path)) {
    fwrite(STDERR, "fincore: usage: fincore.php <file>\n");
    exit(2);
}
$size = filesize($path);
if ($size === 0) {
    echo "fincore: resident_bytes=0 size_bytes=0 pages=0 resident_pages=0\n";
    exit(0);
}
$libc = FFI::cdef('
    int open(const char *path, int flags);
    int close(int fd);
    intptr_t mmap(intptr_t addr, size_t length, int prot, int flags, int fd, long offset);
    int munmap(intptr_t addr, size_t length);
    int mincore(intptr_t addr, size_t length, unsigned char *vec);
    long sysconf(int name);
', 'libc.so.6');
const O_RDONLY = 0;
const PROT_READ = 1;
const MAP_SHARED = 1;
const SC_PAGESIZE = 30;
$page = $libc->sysconf(SC_PAGESIZE);
$fd = $libc->open($path, O_RDONLY);
if ($fd < 0) {
    fwrite(STDERR, "fincore: cannot open $path\n");
    exit(1);
}
$addr = $libc->mmap(0, $size, PROT_READ, MAP_SHARED, $fd, 0);
if ($addr === -1) {
    fwrite(STDERR, "fincore: cannot map $path\n");
    exit(1);
}
$pages = intdiv($size + $page - 1, $page);
$vec = $libc->new("unsigned char[$pages]");
if ($libc->mincore($addr, $size, $vec) !== 0) {
    fwrite(STDERR, "fincore: mincore failed\n");
    exit(1);
}
$resident = 0;
for ($i = 0; $i < $pages; $i++) {
    $resident += $vec[$i] & 1;
}
$libc->munmap($addr, $size);
$libc->close($fd);
echo 'fincore: resident_bytes=' . min($size, $resident * $page) . " size_bytes=$size pages=$pages resident_pages=$resident\n";

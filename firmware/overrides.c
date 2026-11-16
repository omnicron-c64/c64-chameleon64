/* C64 on Chameleon V1.  The default autoboot() loads ROM_FILENAME (config.h):
   C64.ROM, 32 KB = C64 BASIC+KERNAL (16 KB) followed by the 1541 DOS ROM (16 KB).

   Ultimate Command Interface - DOS target ($01), served from the SD card.
   The core queues UCI commands for targets other than its local palette target ($F0)
   and exposes them on the user_io select line:
     C0 R: flags, cmd_len        C1 R: flags, cmd bytes
     C2 W: response data         C3 W: status string
     C4 W: more, rlen_lo, rlen_hi, slen   (commit packet to the C64)
     C5 W: REU base address (3 bytes)
   flags: bit0 command pending, bit1 C64 accepted a "more" packet, bit2 abort
*/

#include <string.h>
#include "config.h"
#include "minfat.h"
#include "swap_le.h"
#include "spi.h"
#include "user_io.h"
#include "menu.h"
#include "diskimg.h"
#include "configstring.h"

#define UCI_FILE_REU 0xc2   /* ioctl index of the REU loader in the core */

#define UBUF 276                   /* largest packet we send (READ_DATA max; Dragon's Lair reads $114) */
#define UCMD 100                    /* longest command kept (Dragon's Lair's longest is ~30 bytes) */
static unsigned char ucmd[UCMD];
static unsigned char ubuf[UBUF];
static int ucmdlen;
static fileTYPE ufile;
static int ufile_open;
static char upath[128] = "/Usb0/";
static char uname[13];

static int xfer(int v)
{
	SPI(v);
	return SPI_READ() & 0xff;
}

static int uci_flags(int *len)
{
	int f;
	EnableIO();
	SPI(0xc0);
	f = xfer(0);
	*len = xfer(0);
	DisableIO();
	return f;
}

static void uci_reply(const unsigned char *data, int dlen, const char *status, int more)
{
	int i, slen = strlen(status);
	if (dlen) {
		EnableIO();
		SPI(0xc2);
		for (i = 0; i < dlen; ++i)
			SPI(data[i]);
		DisableIO();
	}
	if (slen) {
		EnableIO();
		SPI(0xc3);
		for (i = 0; i < slen; ++i)
			SPI(status[i]);
		DisableIO();
	}
	EnableIO();
	SPI(0xc4);
	SPI(more);
	SPI(dlen & 0xff);
	SPI(dlen >> 8);
	SPI(slen);
	DisableIO();
}

/* wait until the C64 has accepted a "more" packet; 0 on abort/timeout */
static int uci_wait_acc(void)
{
	int len, f, t = 2000000;
	while (--t) {
		f = uci_flags(&len);
		if (f & 4)
			return 0;
		if (f & 2)
			return 1;
	}
	return 0;
}

/* display name of the current directory entry: long name or "NAME.EXT" */
static const char *entry_name(DIRENTRY *p)
{
	int i, j = 0;
	if (longfilename[0])
		return longfilename;
	for (i = 0; i < 8 && p->Name[i] != ' '; ++i)
		uname[j++] = p->Name[i];
	if (p->Extension[0] != ' ') {
		uname[j++] = '.';
		for (i = 0; i < 3 && p->Extension[i] != ' '; ++i)
			uname[j++] = p->Extension[i];
	}
	uname[j] = 0;
	return uname;
}

/* find an entry by long name or by its 8.3 display name */
static DIRENTRY *uci_find(const char *name)
{
	DIRENTRY *p = 0;
	while ((p = NextDirEntry(p == 0, 0))) {
		if (strcasecmp(entry_name(p), name) == 0)
			return p;
	}
	return 0;
}

static void open_entry(DIRENTRY *p)
{
	ufile.size = ConvBBBB_LE(p->FileSize);
	ufile.cluster = ConvBB_LE(p->StartCluster);
	ufile.cluster += (fat32 ? (ConvBB_LE(p->HighCluster) & 0x0FFF) << 16 : 0);
	ufile.sector = 0;
	ufile.firstcluster = ufile.cluster;
	ufile.cursor = 0;
}

/* Ultimate-style virtual root: "/" holds the mounts. SD, Usb0 and Usb1 all map to the
   SD card root; Flash maps to a "Flash" folder on the SD card (if present). */
static const char * const mounts[] = { "SD", "Usb0", "Flash", 0 };
static int uvirt;                   /* 1 = at the virtual root "/" */
static unsigned int ucluster;       /* UCI's own current directory (0 = SD root) */
static char *wp;                    /* path being built by CHANGE_DIR (in ubuf) */

static int cd_one(char *c)
{
	DIRENTRY *p;
	char *s;
	int i;
	if (!c[0] || strcmp(c, ".") == 0)
		return 1;
	if (strcmp(c, "..") == 0) {
		if (uvirt)
			return 1;
		for (i = 0, s = wp; *s; ++s)            /* "/Usb0/" = mount root: two slashes */
			if (*s == '/') ++i;
		if (i <= 2) {
			uvirt = 1;
			strcpy(wp, "/");
			ChangeDirectoryByCluster(0);
			return 1;
		}
		ChangeDirectory(uci_find(".."));
		s = wp + strlen(wp) - 2;                /* strip the last "name/" */
		while (s > wp && *s != '/')
			--s;
		s[1] = 0;
		return 1;
	}
	if (uvirt) {
		for (i = 0; mounts[i]; ++i)
			if (strcasecmp(c, mounts[i]) == 0)
				break;
		if (!mounts[i])
			return 0;
		ChangeDirectoryByCluster(0);
		if (i == 2) {                           /* Flash -> SD:/Flash */
			p = uci_find(mounts[i]);
			if (!p || !(p->Attributes & ATTR_DIRECTORY))
				return 0;
			ChangeDirectory(p);
		}
		uvirt = 0;
		strcpy(wp, "/");
		strcat(wp, mounts[i]);
		strcat(wp, "/");
		return 1;
	}
	p = uci_find(c);
	if (!p || !(p->Attributes & ATTR_DIRECTORY))
		return 0;
	ChangeDirectory(p);
	if (strlen(wp) + strlen(c) + 2 < sizeof(upath)) {
		strcat(wp, c);
		strcat(wp, "/");
	}
	return 1;
}

static void cmd_change_dir(char *name)
{
	unsigned int savecl = CurrentDirectory();
	int savevirt = uvirt, ok = 1;
	char *c;
	wp = (char *)ubuf;                          /* work on a copy; upath only changes on success */
	strcpy(wp, upath);
	if (name[0] == '/') {                       /* absolute: start at the virtual root */
		uvirt = 1;
		strcpy(wp, "/");
		ChangeDirectoryByCluster(0);
		++name;
	}
	while (ok && *name) {
		c = name;
		while (*name && *name != '/')
			++name;
		if (*name)
			*name++ = 0;
		ok = cd_one(c);
	}
	if (ok) {
		strcpy(upath, wp);
		uci_reply(0, 0, "00,OK", 0);
	} else {                                    /* restore on failure */
		ChangeDirectoryByCluster(savecl);       /* upath untouched: new path was built in wp */
		uvirt = savevirt;
		uci_reply(0, 0, "83,NO SUCH DIR", 0);
	}
}

static void cmd_read_dir(void)
{
	DIRENTRY *p;
	const char *n;
	int first = 1, l, i;
	if (uvirt) {                                /* the mounts, as directories */
		for (i = 0; mounts[i]; ++i) {
			ubuf[0] = ATTR_DIRECTORY;
			l = strlen(mounts[i]);
			memcpy(ubuf + 1, mounts[i], l);
			uci_reply(ubuf, l + 1, "", 1);
			if (!uci_wait_acc())
				return;
		}
		uci_reply(0, 0, "00,OK", 0);
		return;
	}
	while ((p = NextDirEntry(first, 0))) {
		first = 0;
		if (p->Name[0] == '.')                  /* skip "." and ".." */
			continue;
		n = entry_name(p);
		l = strlen(n);
		if (l > 250) l = 250;
		ubuf[0] = p->Attributes;
		memcpy(ubuf + 1, n, l);
		uci_reply(ubuf, l + 1, "", 1);
		if (!uci_wait_acc())
			return;
	}
	uci_reply(0, 0, "00,OK", 0);
}

/* REU download FIFO (512 bytes) still draining? flag bit 7 */
static void reu_fifo_wait(void)
{
	int len;
	while (uci_flags(&len) & 0x80)
		;
}

static void cmd_load_reu(void)
{
	register volatile int *spiptr = &HW_SPI(HW_SPI_DATA);
	unsigned int addr = ucmd[2] | (ucmd[3] << 8) | (ucmd[4] << 16);
	unsigned int len = ucmd[6] | (ucmd[7] << 8) | (ucmd[8] << 16) | (ucmd[9] << 24);
	int n;
	if (!ufile_open) { uci_reply(0, 0, "84,NO FILE OPEN", 0); return; }
	if (len > ufile.size) len = ufile.size;

	EnableIO();                                 /* REU start address */
	SPI(0xc5); SPI(addr & 0xff); SPI((addr >> 8) & 0xff); SPI((addr >> 16) & 0xff);
	DisableIO();

	EnableFpga(); *spiptr = SPI_FPGA_FILE_INDEX; *spiptr = UCI_FILE_REU; DisableFpga();
	EnableFpga(); *spiptr = SPI_FPGA_FILE_TX;    *spiptr = 1;            DisableFpga();
	while (len) {
		unsigned char *b = sector_buffer;
		n = len > 512 ? 512 : len;
		len -= n;
		if (!FileReadSector(&ufile, sector_buffer)) break;
		reu_fifo_wait();
		EnableFpga();
		*spiptr = SPI_FPGA_FILE_TX_DAT;
		do { *spiptr = *b++; } while (--n);
		DisableFpga();
		FileNextSector(&ufile, 1);
	}
	reu_fifo_wait();
	EnableFpga(); *spiptr = SPI_FPGA_FILE_TX; *spiptr = 0; DisableFpga();
	uci_reply(0, 0, "00,OK", 0);
}

static void uci_dos(void)
{
	char *arg = (char *)ucmd + 2;
	ucmd[ucmdlen] = 0;
	switch (ucmd[1]) {
	case 0x01:  /* IDENTIFY */
		uci_reply((const unsigned char *)"CHAMELEON DOS", 13, "00,OK", 0);
		break;
	case 0x02:  /* OPEN_FILE attrib name */
		ufile_open = 0;
		if (ucmd[2] & 0x0e) {
			uci_reply(0, 0, "26,WRITE PROTECTED", 0);
		} else {
			DIRENTRY *p = uvirt ? 0 : uci_find(arg + 1);
			if (p && !(p->Attributes & ATTR_DIRECTORY)) {
				open_entry(p);
				ufile_open = 1;
				uci_reply(0, 0, "00,OK", 0);
			} else
				uci_reply(0, 0, "62,FILE NOT FOUND", 0);
		}
		break;
	case 0x03:  /* CLOSE_FILE */
		ufile_open = 0;
		uci_reply(0, 0, "00,OK", 0);
		break;
#define UCI_READ_DATA
#ifdef UCI_READ_DATA
	case 0x04:  /* READ_DATA len_lo len_hi */
		if (!ufile_open) {
			uci_reply(0, 0, "84,NO FILE OPEN", 0);
		} else {
			int want = ucmd[2] | (ucmd[3] << 8);
			if (want > UBUF) want = UBUF;
			want = FileRead(&ufile, ubuf, want);
			uci_reply(ubuf, want, "00,OK", 0);
		}
		break;
	case 0x07:  /* FILE_INFO: size (LE) */
		memset(ubuf, 0, 12);
		if (ufile_open) {
			ubuf[0] = ufile.size; ubuf[1] = ufile.size >> 8;
			ubuf[2] = ufile.size >> 16; ubuf[3] = ufile.size >> 24;
		}
		uci_reply(ubuf, 12, ufile_open ? "00,OK" : "84,NO FILE OPEN", 0);
		break;
#endif
	case 0x11:  /* CHANGE_DIR name */
		cmd_change_dir(arg);
		break;
	case 0x12:  /* GET_PATH */
		uci_reply((const unsigned char *)upath, strlen(upath), "00,OK", 0);
		break;
	case 0x13:  /* OPEN_DIR */
		uci_reply(0, 0, "00,OK", 0);
		break;
	case 0x14:  /* READ_DIR */
		cmd_read_dir();
		break;
	case 0x21:  /* LOAD_REU addr(4) len(4) */
		cmd_load_reu();
		break;
	default:
		uci_reply(0, 0, "21,NOT SUPPORTED", 0);
	}
}

static void uci_poll(void)
{
	int len, f = uci_flags(&len);
	if (!(f & 1))
		return;
	if (len > UCMD - 1)
		len = UCMD - 1;
	ucmdlen = len;
	EnableIO();
	SPI(0xc1);
	xfer(0);                                    /* flags */
	for (f = 0; f < len; ++f)
		ucmd[f] = xfer(0);
	DisableIO();
	if (ucmd[0] == 0x01) {
		/* UCI keeps its own current directory, separate from the menu's file browser */
		unsigned int menucl = CurrentDirectory();
		ChangeDirectoryByCluster(ucluster);
		uci_dos();
		ucluster = CurrentDirectory();
		ChangeDirectoryByCluster(menucl);
	} else
		uci_reply(0, 0, "21,NOT SUPPORTED", 0);
}

void mainloop()
{
	while (1) {
#ifdef PS2_MOUSE
		HandlePS2Mouse(0);
#endif
		Menu_Run();
#ifdef CONFIG_DISKIMG
		diskimg_poll();
#endif
		uci_poll();
	}
}

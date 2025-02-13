#!/bin/sh
#
# Make script for BSD Router Project
# https://bsdrp.net
#
# Copyright (c) 2009-2023, The BSDRP Development Team
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#	 notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#	 notice, this list of conditions and the following disclaimer in the
#	 documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE AUTHOR AND CONTRIBUTORS ``AS IS'' AND
# ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
# IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
# ARE DISCLAIMED.  IN NO EVENT SHALL THE AUTHOR OR CONTRIBUTORS BE LIABLE
# FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL
# DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS
# OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
# HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT
# LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY
# OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF
# SUCH DAMAGE.
#

#############################################
############ Variables definition ###########
#############################################

# Exit if error (e) or variable undefined (u)
# Didn't disable filename expansion (f) neither -o pipefail
set -eu

curdir=$(pwd)

#############################################
########### Function definition #############
#############################################

# A usefull function (from: http://code.google.com/p/sh-die/)
die() { echo -n "EXIT: " >&2; echo "$@" >&2; exit 1; }

# BSDRP use META mode for accellerating rebuild process
# And this mode needs filemon
load_module () {
    # $1 : Module name
    if ! kldstat -m $1 > /dev/null 2>&1; then
        echo "$1 module not loaded. Loading it..."
        kldload $1|| die "can't load $1"
    fi
}

# Update or install sources if not already installed
update_src () {
	echo "Updating/Installing FreeBSD sources"

	if [ ! -d "${FREEBSD_SRC}"/.${SRC_METHOD} ]; then
		echo "No existing FreeBSD source tree found: Checking out source..."
		mkdir -p "${FREEBSD_SRC}" || die "Can't create ${FREEBSD_SRC}"
		case ${SRC_METHOD} in
		svn)
			${SVN_CMD} co https://${SRC_REPO} "${FREEBSD_SRC}" -r ${SRC_REV} \
			|| die "Can't check out sources from svn repo"
			;;
		git)
			# cloning
			git clone -b ${SRC_BRANCH} --single-branch "${SRC_REPO}".git "${FREEBSD_SRC}" || die "Can't clone sources from git repo"
			# revert back to previous revision
			cd "${FREEBSD_SRC}"
			git checkout ${SRC_REV}
			echo "Git commit count:"
			git rev-list HEAD --count
			;;
		*)
			[ -d "${FREEBSD_SRC}" ] || \
				die "No FreeBSD source directory found and no supported SRC_METHOD configured"
		esac
	else
		echo "Reverting all local changes..."
		case ${SRC_METHOD} in
		svn)
			#Checking repo change
			if ! ${SVN_CMD} info "${FREEBSD_SRC}" | grep -q "${SRC_REPO}"; then
				die "svn repo changed: delete your source tree with rm -rf ${FREEBSD_SRC}"
				die "or relocate it: cd {FREEBSD_SRC}; svn relocate svn://svn.freebsd.org https://svn.freebsd.org"
			fi
			echo "Cleaning local FreeBSD patches..."
			#cleaning local patced source
			if [ ${SRC_METHOD} = "svn" ]; then
				${SVN_CMD} revert -R "${FREEBSD_SRC}"
				${SVN_CMD} cleanup "${FREEBSD_SRC}" --remove-unversioned
			fi
			;;
		git)
			(
				cd "${FREEBSD_SRC}"
				git checkout .
				git clean -fd
			)
			# git restore :/
			;;
		*)
			die "Unknown method"
		esac

		echo "Updating FreeBSD sources..."
		case ${SRC_METHOD} in
		svn)
			${SVN_CMD} update "${FREEBSD_SRC}" -r ${SRC_REV} || die "Can't update FreeBSD src"
			;;
		git)
			cd "${FREEBSD_SRC}"
			git pull --ff-only
			git checkout ${SRC_REV}
			# Or:
			# git reset --hard ${SRC_REV}
			;;
		*)
			die "Unknown method: ${SRC_METHOD}"
		esac
	fi
}

update_port () {
	echo "Updating/Installing ports tree"
	if [ ! -d "${PORTS_SRC}"/.git ]; then
		echo "No existing source port tree found: Checking out ports source..."
		# cloning
		git clone -b ${PORTS_BRANCH} --single-branch "${PORTS_REPO}".git "${PORTS_SRC}" || die "Can't clone sources from git repo"
			# revert back to previous revision
			cd "${PORTS_SRC}"
			git checkout ${PORTS_REV}
			echo "Git commit count:"
			git rev-list HEAD --count
	else
		#cleaning local patched ports sources
		echo "Reverting local changes and updating..."
		(
			cd "${PORTS_SRC}"
			git checkout .
			git clean -fd
			git pull --ff-only
			git checkout ${PORTS_REV}
		)
		[ -f "${PROJECT_DIR}"/FreeBSD/ports-added ] && rm "${PROJECT_DIR}"/FreeBSD/ports-added || true
	fi
}

#patch the source tree
patch_src() {
	mkdir -p "${PROJECT_DIR}/FreeBSD/"
	: > "${PROJECT_DIR}/FreeBSD/src-patches"
	for patch in $(cd "${SRC_PATCH_DIR}" && ls freebsd.*.patch); do
		if ! grep -q $patch "${PROJECT_DIR}/FreeBSD/src-patches"; then
			echo "Applying patch $patch..."
			if grep -q 'diff --git a/' "${SRC_PATCH_DIR}"/$patch; then
				p="-p1"
			else
				p="-p0"
			fi
			patch $p -NE -d "${FREEBSD_SRC}" -i "${SRC_PATCH_DIR}"/$patch || die "Source tree patch failed"
			echo $patch >> "${PROJECT_DIR}"/FreeBSD/src-patches
		fi
	done
	# SVN modify files permission to 600, and this create problem if source tree is used by poudriere
	find "${FREEBSD_SRC}" -perm u=rw | xargs chmod 644
}

#patch the port tree
#TODO: avoid copy/past with patch_src()
patch_port() {
	: > "${PROJECT_DIR}"/FreeBSD/ports-patches
	for patch in $(cd "${PORT_PATCH_DIR}" && ls ports.*.patch); do
		if ! grep -q $patch "${PROJECT_DIR}/FreeBSD/ports-patches"; then
			echo "Applying patch $patch..."
			if grep -q 'diff --git a/' "${SRC_PATCH_DIR}"/$patch; then
				p="-p1"
			else
				p="-p0"
			fi
			patch $p -NE -d "${PORTS_SRC}" -i "${PORT_PATCH_DIR}"/$patch || die "Port tree patch failed"
			echo $patch >> "${PROJECT_DIR}"/FreeBSD/ports-patches
		fi
	done
	# SVN modify files permission to 600, and this create problem if source tree is used by poudriere
	find "${PORTS_SRC}" -perm u=rw | xargs chmod 644
}

#Add new ports (in shar format)
add_new_port() {
	for ports in $(cd "${PORT_PATCH_DIR}" && ls ports.*.shar); do
		if ! grep -q $ports "${PROJECT_DIR}"/FreeBSD/ports-added; then
			echo "Adding port $ports..."
			(cd "${PORTS_SRC}" &&
			sh "${PORT_PATCH_DIR}"/$ports)
			echo $ports >> "${PROJECT_DIR}"/FreeBSD/ports-added
		fi
	done
}

##### Check if previous NanoBSD make stop correctly by unoumt all tmp mount
# exit with 0 if no problem detected
# exit with 1 if problem detected, but clean it
# exit with 2 if problem detected and can't clean it
check_clean() {
	# Check all working dir allready mounted and unmount them
	# Patch from Warner Losh (imp@)
	__a=`mount | grep $1 | awk '{print length($3), $3;}' | sort -rn \
	    | awk '{$1=""; print;}'`
	if [ -n "$__a" ]; then
		echo "unmounting $__a"
		umount $__a
	fi
}

usage () {
	(
		echo "Usage: $0 -bdhkuryw [-c vga|serial] [-p PROJECT]"
		echo " -b   suppress build[world|kernel]"
		echo " -c   specify console type: vga (default) or serial"
		echo " -C   force a cleanup of previous object files"
		echo " -f   fast mode, skip: images compression and checksums"
		echo " -h   display this help message"
		echo " -k   suppress [build|install]kernel"
		echo " -p   project name to build"
		echo " -s   size in MB of the target disk (default: 1000)"
		echo " -u   update all src (freebsd and ports)"
		echo " -U   update all src ONLY (no build)"
		echo " -r   use a memory disk as destination dir"
		echo " -y   Answer yes to all confirmation"
		echo " -w   suppress buildworld"
	) 1>&2
	exit 2
}

#############################################
############ Main code ######################
#############################################

echo "BSD Router Project image build script"
echo ""

# XZ command line
XZ="xz -9 -T0 -vf"
# Temporary (working) directory
TMPDIR="$(pwd)"/workdir
# Is svn or svnlite available ?
SVN_CMD=$(which svn) || SVN_CMD=$(which svnlite) || true
# script (make.sh) file name
SCRIPT=$(readlink -f $0)
# directory where make.sh file is
SCRIPT_DIR=$(dirname "$SCRIPT")
# boolean for answering YES automatically
ALWAYS_YES=false
# Host arch (i386, amd64, aarch64, etc.)
LOCAL_ARCH=$(uname -p)
# Project name, set by default to BSDRP, need to be an existing subdir
PROJECT="BSDRP"
# Target architecture for the image to build
TARGET_ARCH=${LOCAL_ARCH}
NANO_KERNEL=${TARGET_ARCH}
# For skiping some build part (world, kernel)
SKIP_REBUILD=""
# Console type -vga, -console or none ""
INPUT_CONSOLE="-vga"
# Boolean for fast mode (skip mtree and xziping final image)
FAST=false
# Boolean for updating or not the source tree (FreeBSD and port tree)
UPDATE_SRC=false
UPDATE_PORT=false
# Boolean for update only
UPDATE_ONLY=false
# Boolean for using TMPFS
TMPFS=false
# Boolean for forcing a cleanup
NOCLEAN="-n"

#Get argument
while getopts "bCc:dfhkp:s:uUryw" arg; do
	case "${arg}" in
		b)
			SKIP_REBUILD="${SKIP_REBUILD} -b"
			;;
		c)
			case "$OPTARG" in
				vga)
					INPUT_CONSOLE="-vga"
					;;
				serial)
					INPUT_CONSOLE="-serial"
					;;
				*)
					die "ERROR: Bad console type"
			esac
			;;
		C)
			NOCLEAN=""
			;;
		f)
			FAST=true
			;;
		h)
			usage
			;;
		k)
			SKIP_REBUILD="${SKIP_REBUILD} -kK"
			;;
		p)
			PROJECT=$OPTARG
			;;
		u)
			UPDATE_SRC=true
			UPDATE_PORT=true
			;;
		U)
			UPDATE_SRC=true
			UPDATE_PORT=true
			UPDATE_ONLY=true
			;;

		r)
			TMPFS=true
			;;
		s)
			DISK_SIZE=$OPTARG
			;;
		y)
			ALWAYS_YES=true
			;;
		w)
			SKIP_REBUILD="${SKIP_REBUILD} -w"
			;;
		*)
			echo "Unknown parameter: $OPTARG"
			usage
			;;
		esac
done
shift $(( OPTIND - 1 ))

if [ $# -gt 0 ] ; then
	echo "$0: Extraneous arguments supplied"
	usage
fi

# Number of jobs
MAKE_JOBS=$(sysctl -n kern.smp.cpus)

# Checking TARGET folder
[ -d "${SCRIPT_DIR}/${PROJECT}" ] || die "Can't found target ${PROJECT}"

PROJECT_DIR="${SCRIPT_DIR}/${PROJECT}"
KERNELS_DIR="${PROJECT_DIR}/kernels"
NANO_DIRS_INSTALL="${PROJECT_DIR}/Files"

# Loading the project variables stored in $PROJECT/make.conf
# Once loaded, all these variables will be available:
# -NAME: Name of the Project
# -MASTER_PROJECT: For a child projet, name of the father project
# -SRC_REV="13b3862ee87"
# -PORTS_REV="d73721414d8d"
# -SRC_METHOD="git"
# -SRC_REPO: FreeBSD base source tree repository
# -SRC_BRANCH: Branch to use
# -PORTS_REPO: FreeBSD port source tree repository
# -PORTS_BRANCH: Branch to use
# -FREEBSD_SRC: directory for localy stored FreeBSD source tree
# -SRC_PATCH_DIR: Directory for FreeBSD patches
# -PORTS_SRC: Directory for localy stored ports source tree
# -PORT_PATCH_DIR: Directory for port patches
# -NANOBSD_DIR: Where the nanobsd tree lives
# -NANO_MODULES_ARCH: List of kernel modules to build for ARCH
# -DISK_SIZE: Target size of the flash disk media

. "${SCRIPT_DIR}"/${PROJECT}/make.conf

# Check if no previously mounted dirs
check_clean ${PROJECT}.${TARGET_ARCH}

# Loading filemon if not already
load_module filemon

if [ -n "${MASTER_PROJECT}" ]; then
	# It's a child project: Load MASTER_PROJECT/make.conf
	# But set PROJECT_DIR to MASTER_PROJECT before calling make.conf
	PROJECT_DIR="${SCRIPT_DIR}/${MASTER_PROJECT}"
	. "${SCRIPT_DIR}"/${MASTER_PROJECT}/make.conf
	# Now overide variables learn on MASTER_PROJECT by our child one
	PROJECT_DIR="${SCRIPT_DIR}/${PROJECT}"
	. "${SCRIPT_DIR}"/${PROJECT}/make.conf
	MASTER_PROJECT_DIR="${SCRIPT_DIR}/${MASTER_PROJECT}"
	trap "echo 'Running exit trap code' ; check_clean ${PROJECT}.${TARGET_ARCH}" 1 2 15 EXIT
	# If there is no kernels config on sub-project, use the master dir
	[ -d "${PROJECT_DIR}"/kernels ] ||
	  KERNELS_DIR="${MASTER_PROJECT_DIR}/kernels"
	if [ -d "${PROJECT_DIR}"/Files ]; then
		NANO_DIRS_INSTALL="${MASTER_PROJECT_DIR}/Files ${PROJECT_DIR}/Files"
	else
		NANO_DIRS_INSTALL="${MASTER_PROJECT_DIR}/Files"
	fi
fi

# project version
for dir in ${NANO_DIRS_INSTALL}; do
	[ -z "${dir}" ] && die "Bug: Empty NANO_DIRS_INSTALL variable"
	if [ -f "${dir}"/etc/version ]; then
		VERSION=$(cat "${dir}"/etc/version)
	else
		die "No ${dir}/etc/version found"
	fi
done

# Check for a kernel
[ -f "${KERNELS_DIR}"/${NANO_KERNEL} ] || die "Can't found kernels/${NANO_KERNEL}"

if [ $(sysctl -n hw.usermem) -lt 2000000000 ]; then
	echo "WARNING: Not enough hw.usermem available, disable memory disk usage"
	TMPFS=false
fi

mkdir -p "${TMPDIR}" || die "ERROR: Cannot create ${TMPDIR}"

if ($TMPFS); then
	if mount | grep -q -e "^tmpfs[[:space:]].*${TMPDIR}/tmpfs[[:space:]]"; then
		echo "Existing tmpfs file system detected"
	else
		mkdir -p "${TMPDIR}"/tmpfs || die "ERROR: Cannot create tmpfs"
fi
		# only root can use mount -t tmpfs
		if [ "$(id -u)" != "0" ]; then
   			die "Need to be root for issuing 'mount -t tmpfs tmpfs ${TMPDIR}/tmpfs'"
		else
		mount -t tmpfs tmpfs "${TMPDIR}"/tmpfs || die "ERROR: Cannot mount a tmpfs"
		fi
	NANO_OBJ="${TMPDIR}"/tmpfs/${PROJECT}.${NANO_KERNEL}
else
	NANO_OBJ="${TMPDIR}"/${PROJECT}.${NANO_KERNEL}
fi
if [ -n "${SKIP_REBUILD}" ]; then
	if ! [ -d ${NANO_OBJ} ]; then
		SKIP_REBUILD=""
		echo "WARNING: No previous object directory found (${NANO_OBJ}, you can't skip some rebuild"
	fi
fi

# Check if no previously tempo obj folder still mounted
check_clean "${NANO_OBJ}"

# If no source installed, force installing them
[ -d "${FREEBSD_SRC}" ] || UPDATE_SRC=true

#Check if the project uses port before installing/updating port tree
if grep -q '^add_port[[:blank:]]\+"' "${PROJECT_DIR}"/${NAME}.nano; then
	[ -d "${PORTS_SRC}"/.${SRC_METHOD} ] || UPDATE_PORT=true
	PROJECT_WITH_PORT=true
else
	PROJECT_WITH_PORT=false
	UPDATE_PORT=false
fi
echo "Will generate an ${NAME} image with theses values:"
echo "- Target architecture: ${NANO_KERNEL}"
[ -n "${INPUT_CONSOLE}" ] && echo "- Console : ${INPUT_CONSOLE}"

echo "- Target disk size (in MB): ${DISK_SIZE}"
echo -n "- Source Updating/installing: "
($UPDATE_SRC) && echo "YES" || echo "NO"

echo -n "- Port tree Updating/installing: "
($UPDATE_PORT) && echo "YES" || echo "NO"

echo -n "- Build the full world (take about 1 hour): "
[ -z "${SKIP_REBUILD}" ] && echo "YES" || echo "NO"

echo -n "- FAST mode (skip compression and checksumming): "
(${FAST}) && echo "YES" || echo "NO"

echo -n "- TMPFS: "
($TMPFS) && echo "YES" || echo "NO"

##### Generating the nanobsd configuration file ####

# Theses variables must be set on the begining
{
echo "# Name of this NanoBSD build (Used to construct workdir names)"
echo "NANO_NAME=${NAME}"
echo "# Source tree directory"
echo "NANO_SRC=\"${FREEBSD_SRC}\""
} > "${TMPDIR}"/${PROJECT}.nano
if ($PROJECT_WITH_PORT); then
	{
	echo "# Where the port tree is"
	echo "PORTS_SRC=\"${PORTS_SRC}\""
	} >> "${TMPDIR}"/${PROJECT}.nano
fi

{
echo "# Where nanobsd additional files live under the source tree"
echo "NANO_TOOLS=\"${PROJECT_DIR}\""
echo "NANO_OBJ=\"${NANO_OBJ}\""
echo "NANO_DIRS_INSTALL=\"${NANO_DIRS_INSTALL}\""
} >> "${TMPDIR}"/${PROJECT}.nano

# Copy the common nanobsd configuration file to /tmp
if [ -f "${PROJECT_DIR}"/${NAME}.nano ]; then
	cat "${PROJECT_DIR}"/${NAME}.nano >> "${TMPDIR}"/${PROJECT}.nano
else
	die "No ${NAME}.nano configuration files"
fi

# And add the customized variable to the nanobsd configuration file
{
echo "############# Variable section (generated by BSDRP make.sh) ###########"
echo "# The default name for any image we create."
echo "NANO_IMGNAME=\"${NAME}-${VERSION}-full-${NANO_KERNEL}${INPUT_CONSOLE}.img\""
echo "# Kernel config file to use"
echo "NANO_KERNEL=${NANO_KERNEL}"

# Set physical disk layout for generic USB of 256MB (244MiB)
# Explanation:  Vendors baddly convert 256 000 000 Byte as 256MB
#               But, 256 000 000 Byte is 244MiB
# This function will set the variable NANO_MEDIASIZE, NANO_SECTS, NANO_HEADS
# Warning : using generic-fdd (heads=64 sectors/track=32) create boot problem on WRAP
echo "# Target disk size"
echo "UsbDevice generic-hdd ${DISK_SIZE}"

echo "# Parallel Make"
# Special ARCH commands
# Note for modules names: They are relative to /usr/src/sys/modules
echo "NANO_PMAKE=\"make -j ${MAKE_JOBS}\""
} >> "${TMPDIR}"/${PROJECT}.nano

eval echo NANO_MODULES=\\\"\${NANO_MODULES_${NANO_KERNEL}}\\\" >> "${TMPDIR}"/${PROJECT}.nano
case ${NANO_KERNEL} in
	"i386_xenpv" | "i386_xenhvm" | "amd64_xenhvm" | "amd64_xenpv" )
		#echo "add_port \"lang/python27\" \"-DNOPORTDATA\"" >> /tmp/${PROJECT}.nano
		#echo "add_port \"sysutils/xen-tools\"" >> /tmp/${PROJECT}.nano
		{
		echo "#Configure xen console port"
        echo "customize_cmd bsdrp_console_xen"
		} >> "${TMPDIR}"/${PROJECT}.nano
		;;
esac

echo "# Bootloader type"  >> "${TMPDIR}"/${PROJECT}.nano

case ${INPUT_CONSOLE} in
	"-vga")
		{
		echo "NANO_BOOTLOADER=\"boot/boot0\""
		# Configuring dual_console (vga and serial) can cause problem to
		# some computer that have special serial port
		echo "#Configure vga console port"
		echo "customize_cmd bsdrp_console_vga"
		} >> "${TMPDIR}"/${PROJECT}.nano
		;;
	"-serial")
		{
		echo "NANO_BOOTLOADER=\"boot/boot0sio\""
		echo "#Configure serial console port"
		echo "customize_cmd bsdrp_console_serial"
		} >> "${TMPDIR}"/${PROJECT}.nano
		;;
esac

# Delete the destination dir
# BUG: since skip_rebuild is by default "-n", this code can't never be triggered
if [ -z "${NOCLEAN}" ]; then
#if [ -z "${SKIP_REBUILD}" ]; then
	if [ -d ${NANO_OBJ} ]; then
		echo "Existing working directory detected (${NANO_OBJ}),"
		echo "but you asked for rebuild some parts (no -b, -w or -k option given)"
		echo "or a force clean"
		echo "Do you want to continue ? (y/n)"
		if ! ${ALWAYS_YES}; then
			USER_CONFIRM=""
			while [ "$USER_CONFIRM" != "y" -a "$USER_CONFIRM" != "n" ]; do
				read USER_CONFIRM <&1
			done
			[ "$USER_CONFIRM" = "n" ] && exit 0
		fi
		echo "Delete existing ${NANO_OBJ} directory"
		chflags -R noschg ${NANO_OBJ}
		rm -rf ${NANO_OBJ}
	fi
fi

#### Udpate or install source ####
if [ -n "${SRC_REPO}" ]; then
	if ($UPDATE_SRC); then
		echo "Update sources..."
		update_src
		echo "Patch sources..."
		patch_src
	fi
fi

if [ -n "${PORTS_REPO}" ]; then
	if ($UPDATE_PORT); then
		echo "Update port tree..."
   		update_port
		echo "Patch sources..."
   		patch_port
		echo "Add ports..."
		add_new_port
	fi
fi
# Export some variables for using them under nanobsd
# Somes ports needs the correct uname -r output
REV=$(grep -m 1 REVISION= "${FREEBSD_SRC}/sys/conf/newvers.sh" | cut -f2 -d '"')
BRA=$(grep -m 1 BRANCH=	"${FREEBSD_SRC}/sys/conf/newvers.sh" | cut -f2 -d '"')
export FBSD_DST_RELEASE="${REV}-${BRA}"
export FBSD_DST_OSVERSION=$(awk '/^\#define[[:blank:]]__FreeBSD_version/ {print $3}' \
    "${FREEBSD_SRC}/sys/sys/param.h")

echo "Copying ${NANO_KERNEL} Kernel configuration file"
cp "${KERNELS_DIR}"/${NANO_KERNEL} "${FREEBSD_SRC}"/sys/${TARGET_ARCH}/conf/

if ($UPDATE_ONLY); then
	echo "Update ONLY done!"
	exit 0
fi

# Overwrite the nanobsd script with the latest version (and customized)
# Mandatory for supporting multiple folders to be installed
cd ${curdir}
cp tools/defaults.sh "${NANOBSD_DIR}"/
cp tools/legacy.sh "${NANOBSD_DIR}"/
cp tools/nanobsd.sh "${NANOBSD_DIR}"/
chmod +x "${NANOBSD_DIR}"/nanobsd.sh

# Start nanobsd using the BSDRP configuration file
echo "Launching NanoBSD build process..."
cd "${NANOBSD_DIR}"
set +e
sh "${NANOBSD_DIR}"/nanobsd.sh ${NOCLEAN} ${SKIP_REBUILD} -c "${TMPDIR}"/${PROJECT}.nano
ERROR_CODE=$?
set -e
if [ -n "${MASTER_PROJECT}" ]; then
	# unmount previosly mounted dir (old unionfs code???)
	check_clean "${NANO_OBJ}"
	trap - 1 2 15 EXIT
fi

# Testing exit code of NanoBSD:
if [ ${ERROR_CODE} -eq 0 ]; then
	echo "NanoBSD build seems finish successfully."
else
	echo "ERROR: NanoBSD meet an error, check the log files here:"
	echo "${NANO_OBJ}/"
	LAST_LOG=$(ls -t ${NANO_OBJ}/ | head -n1)
	if file -b ${NANO_OBJ}/${LAST_LOG} | grep -q 'ASCII text'; then
		echo "Displaying fatal error context of ${NANO_OBJ}/${LAST_LOG}"
		# tail -n 400 ${NANO_OBJ}/${LAST_LOG}
		grep -C 5 -m 1 -wi 'error' ${NANO_OBJ}/${LAST_LOG} || true
		grep -C 5 -m 1 'exit code 1' ${NANO_OBJ}/${LAST_LOG} || true
	fi
	exit 1
fi

# The exit code on NanoBSD doesn't work for port compilation/installation
if [ ! -f "${NANO_OBJ}"/_.disk.image ]; then
	echo "ERROR: NanoBSD meet an error (port installation/compilation ?)"
	exit 1
fi

# Renaming debug/symbol files archive
if [ -f ${NANO_OBJ}/debug.tar.xz ]; then
	FILENAME="${NAME}-${VERSION}-debug-${NANO_KERNEL}.tar.xz"
	mv "${NANO_OBJ}"/debug.tar.xz "${NANO_OBJ}"/${FILENAME}
	echo "Debug files archive here:"
	echo "${NANO_OBJ}/${FILENAME}"
fi

# Renaming and compressing upgrade image
FILENAME="${NAME}-${VERSION}-upgrade-${NANO_KERNEL}${INPUT_CONSOLE}.img"

#Remove old upgrade images if present
[ -f "${NANO_OBJ}"/${FILENAME} ] && rm ${NANO_OBJ}/${FILENAME}
[ -f "${NANO_OBJ}"/${FILENAME}.xz ] && rm ${NANO_OBJ}/${FILENAME}.xz

mv "${NANO_OBJ}"/_.disk.image "${NANO_OBJ}"/${FILENAME}

if ! $FAST; then
	if echo ${NANO_KERNEL} | grep -q xenpv -; then
		mv "${NANO_OBJ}"/${FILENAME} "${NANO_OBJ}"/${NAME}-${VERSION}-upgrade-${NANO_KERNEL}.img
        FILENAME="${NAME}-${VERSION}-upgrade-${NANO_KERNEL}.img"
	fi
	echo "Compressing ${NAME} upgrade image..."
	${XZ} "${NANO_OBJ}"/${FILENAME}
	echo "Generating checksum for ${NAME} upgrade image..."
	sha256 "${NANO_OBJ}"/${FILENAME}.xz > "${NANO_OBJ}"/${FILENAME}.sha256
	echo "${NAME} upgrade image file here:"
	echo "${NANO_OBJ}/${FILENAME}.xz"
else
	echo "Uncompressed ${NAME} upgrade image file here:"
	echo "${NANO_OBJ}/${FILENAME}"
fi

# Now renamning/xzing the full image
FILENAME="${NAME}-${VERSION}-full-${NANO_KERNEL}${INPUT_CONSOLE}.img"

#Remove old images if present
[ -f "${NANO_OBJ}"/${FILENAME}.xz ] && rm "${NANO_OBJ}"/${FILENAME}.xz
if ! $FAST; then
	if echo ${NANO_KERNEL} | grep -q xenpv -; then
		mv "${NANO_OBJ}"/${FILENAME} "${NANO_OBJ}"/${NAME}-${VERSION}-full-${NANO_KERNEL}.img
		FILENAME="${NAME}-${VERSION}-full-${NANO_KERNEL}"
		[ -f "${NANO_OBJ}"/${FILENAME}.tar.xz ] && rm "${NANO_OBJ}"/${FILENAME}.tar.xz
    	echo "Generate the XEN PV archive..."
		cat <<EOF > "${NANO_OBJ}"/${FILENAME}.conf
name = "${NAME}-${NANO_KERNEL}"
memory = 196
disk = [ 'file:${FILENAME}.img,hda,w']
vif = [' ']
kernel = "${FILENAME}.kernel.gz"
extra = ",vfs.root.mountfrom=ufs:/ufs/BSDRPs1a"
EOF
		cp "${NANO_OBJ}"/_.w/boot/kernel/kernel.gz "${NANO_OBJ}"/${NAME}-${NANO_KERNEL}.kernel.gz
		tar cvfJ "${NANO_OBJ}"/${FILENAME}.tar.xz \
			-C ${NANO_OBJ} \
			${FILENAME}.conf \
			${FILENAME}.img	\
			${NAME}-${NANO_KERNEL}.kernel.gz
		rm "${NANO_OBJ}"/${FILENAME}.conf
		rm "${NANO_OBJ}"/${FILENAME}.img
		rm "${NANO_OBJ}"/${NAME}-${NANO_KERNEL}.kernel.gz
		echo "Generating checksum for ${NAME} Xen archive..."
        sha256 "${NANO_OBJ}"/${FILENAME}.tar.xz > "${NANO_OBJ}"/${FILENAME}.sha256
		echo "${NANO_OBJ}/${FILENAME}.tar.xz include:"
		echo "- XEN example configuration file: ${FILENAME}.conf"
		echo "- The disk image: ${FILENAME}.img"
		echo "- The extracted kernel: ${NANO_KERNEL}.kernel.gz"
		mv "${NANO_OBJ}"/_.mtree "${NANO_OBJ}"/${NAME}-${VERSION}-${NANO_KERNEL}.mtree
		FILENAME="${NAME}-${VERSION}-${NANO_KERNEL}"
	else
		echo "Compressing ${NAME} full image..."
		${XZ} "${NANO_OBJ}"/${FILENAME}
		echo "Generating checksum for ${NAME} full image..."
		sha256 "${NANO_OBJ}"/${FILENAME}.xz > ${NANO_OBJ}/${FILENAME}.sha256
		echo "Zipped ${NAME} full image file here:"
		echo "${NANO_OBJ}/${FILENAME}.xz"
		mv "${NANO_OBJ}"/_.mtree ${NANO_OBJ}/${NAME}-${VERSION}-${NANO_KERNEL}${INPUT_CONSOLE}.mtree
		FILENAME="${NAME}-${VERSION}-${NANO_KERNEL}${INPUT_CONSOLE}"
	fi
	echo "Zipping and renaming mtree..."
	[ -f "${NANO_OBJ}"/${FILENAME}.mtree.xz ] && rm "${NANO_OBJ}"/${FILENAME}.mtree.xz
	${XZ} "${NANO_OBJ}"/${FILENAME}.mtree
	echo "HIDS reference file here:"
    echo "${NANO_OBJ}/${FILENAME}.mtree.xz"
else
	echo "Unzipped ${NAME} full image file here:"
	echo "${NANO_OBJ}/${FILENAME}"
	echo "Unzipped HIDS reference file here:"
	echo "${NANO_OBJ}/_.mtree"
fi

($TMPFS) && echo "Remember, remember the ${NANO_OBJ} is a tmpfs volume"

echo "Done !"
exit 0

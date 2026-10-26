#!/usr/bin/env python3
"""Cold Avro trajectory for one wiretrack Japan aircraft.

Aircraft W2 (DIS 1:1:2), center of the East China Sea group in
~/wiretrack/test/japan/driver.py. It departs 31 N, 122 E at 8000 m and
flies to Tokyo (35.68 N, 139.76 E) at 220 m/s. The driver steps that
route at 5 Hz on an equirectangular chart. This file is the same route
as a constant-height WGS84 geodesic.

Every vector is ECEF. Position, velocity, and acceleration are the
earth-fixed kinematic state: acceleration is d^2(r)/dt^2, not specific
force. The quaternion rotates the aircraft body into that same ECEF
frame. Body axes are right-handed FLU: +X nose, +Y left wing, +Z up.
"""

import math
import struct
import zlib

from geographiclib.geodesic import Geodesic

# WGS84 (NIMA TR8350.2).
A = 6378137.0
F = 1.0 / 298.257223563
B = A * (1.0 - F)
E2 = F * (2.0 - F)
OMEGA = 7.2921151467e-5  # rad/s
GM = 3.986004418e14
GAMMA_E = 9.7803253359  # equatorial normal gravity, m/s^2
GAMMA_P = 9.8321849378
K_SOM = B * GAMMA_P / (A * GAMMA_E) - 1.0

# wiretrack test/japan/driver.py — one aircraft, group W entity 2.
TOKYO_LAT = 35.68
TOKYO_LON = 139.76
START_LAT = 31.0
START_LON = 122.0
ALT_M = 8000.0
SPEED_MPS = 220.0

# Path curvature is microhertz. 10 Hz keeps linear interpolation of
# velocity and acceleration, and slerp of the quaternion, far below a
# millimetre and a microradian on this route.
HZ = 10.0

SCHEMA = """{
  "type": "record",
  "name": "ColdTrajectory",
  "namespace": "qemu_sim",
  "doc": "One wiretrack Japan aircraft, W2 (DIS 1:1:2). Departs 31.0 N 122.0 E at 8000 m ellipsoidal height and flies the WGS84 geodesic to 35.68 N 139.76 E at a constant 220 m/s ground speed. x_m,y_m,z_m, vx_mps,vy_mps,vz_mps, and ax_mps2,ay_mps2,az_mps2 are ECEF position (m), velocity (m/s), and kinematic acceleration (m/s^2, the second derivative of ECEF position). qw,qx,qy,qz is a Hamilton quaternion, scalar first, rotating aircraft body vectors into ECEF. Body frame is FLU: +X nose, +Y left wing, +Z up. Attitude is coordinated cruise: nose on track, pitch level, bank set so lateral specific force is zero. t_s is seconds from departure.",
  "fields": [
    {"name": "t_s", "type": "double"},
    {"name": "x_m", "type": "double"},
    {"name": "y_m", "type": "double"},
    {"name": "z_m", "type": "double"},
    {"name": "vx_mps", "type": "double"},
    {"name": "vy_mps", "type": "double"},
    {"name": "vz_mps", "type": "double"},
    {"name": "ax_mps2", "type": "double"},
    {"name": "ay_mps2", "type": "double"},
    {"name": "az_mps2", "type": "double"},
    {"name": "qw", "type": "double"},
    {"name": "qx", "type": "double"},
    {"name": "qy", "type": "double"},
    {"name": "qz", "type": "double"}
  ]
}"""

SYNC = b"qemu-sim-japanW2"  # 16 bytes, fixed so the file is reproducible
FIELDS = (
    "t_s",
    "x_m", "y_m", "z_m",
    "vx_mps", "vy_mps", "vz_mps",
    "ax_mps2", "ay_mps2", "az_mps2",
    "qw", "qx", "qy", "qz",
)


def radii(phi):
    """Meridian and prime-vertical radii of curvature."""
    s2 = math.sin(phi) ** 2
    rn = A / math.sqrt(1.0 - E2 * s2)
    rm = A * (1.0 - E2) / (1.0 - E2 * s2) ** 1.5
    return rm, rn


def gravity(phi, h):
    """Normal gravity along the ellipsoidal normal, m/s^2, positive down."""
    s2 = math.sin(phi) ** 2
    gamma = GAMMA_E * (1.0 + K_SOM * s2) / math.sqrt(1.0 - E2 * s2)
    m = OMEGA * OMEGA * A * A * B / GM
    return gamma * (
        1.0
        - (2.0 / A) * (1.0 + F + m - 2.0 * F * s2) * h
        + 3.0 * h * h / (A * A)
    )


def geodetic_to_ecef(lat_deg, lon_deg, h):
    phi, lam = math.radians(lat_deg), math.radians(lon_deg)
    sl, cl = math.sin(phi), math.cos(phi)
    rn = A / math.sqrt(1.0 - E2 * sl * sl)
    return (
        (rn + h) * cl * math.cos(lam),
        (rn + h) * cl * math.sin(lam),
        (rn * (1.0 - E2) + h) * sl,
    )


# Karney's algorithm. Vincenty is a couple of centimetres off on this route.
GEOD = Geodesic.WGS84


def geodesic_inverse(lat1, lon1, lat2, lon2):
    """Distance (m) and forward azimuths (rad) on the WGS84 ellipsoid."""
    r = GEOD.Inverse(lat1, lon1, lat2, lon2)
    return r["s12"], math.radians(r["azi1"]), math.radians(r["azi2"])


def geodesic_direct(lat1, lon1, azi1, s):
    """Point and arrival azimuth after s metres along the geodesic."""
    r = GEOD.Direct(lat1, lon1, math.degrees(azi1), s)
    return r["lat2"], r["lon2"], math.radians(r["azi2"])


def height_scale(phi, alpha):
    """ds_at_altitude / ds_on_ellipsoid for the same lat/lon step."""
    rm, rn = radii(phi)
    ca, sa = math.cos(alpha), math.sin(alpha)
    return math.hypot((rm + ALT_M) / rm * ca, (rn + ALT_M) / rn * sa)


def build_time_table(distance_m, azi0):
    """Surface distance vs time, so ground speed at altitude is SPEED_MPS."""
    step = 500.0
    ss = [0.0]
    tt = [0.0]
    s = 0.0
    lat, lon, alpha = START_LAT, START_LON, azi0
    while s < distance_m:
        ds = min(step, distance_m - s)
        lat2, lon2, alpha2 = geodesic_direct(START_LAT, START_LON, azi0, s + ds)
        # Trapezoid on the local scale. Direct from the origin, so this does not accumulate.
        scale = 0.5 * (height_scale(math.radians(lat), alpha) + height_scale(math.radians(lat2), alpha2))
        s += ds
        ss.append(s)
        tt.append(tt[-1] + scale * ds / SPEED_MPS)
        lat, lon, alpha = lat2, lon2, alpha2
    return ss, tt


def surface_distance_at(t, ss, tt):
    if t <= 0.0:
        return 0.0
    if t >= tt[-1]:
        return ss[-1]
    lo, hi = 0, len(tt) - 1
    while hi - lo > 1:
        mid = (lo + hi) // 2
        if tt[mid] <= t:
            lo = mid
        else:
            hi = mid
    span = tt[hi] - tt[lo]
    frac = 0.0 if span == 0.0 else (t - tt[lo]) / span
    return ss[lo] + frac * (ss[hi] - ss[lo])


def specific_force_ned(phi, alpha):
    """Specific force in NED for constant-speed, constant-height geodesic flight.

    f = v_dot + (2*w_ie + w_en) x v - g, with g positive down (Groves).
    Horizontal transport cancels the heading-rate term, leaving Coriolis
    in north/east and path curvature plus the Eotvos term in down.
    """
    rm, rn = radii(phi)
    vn = SPEED_MPS * math.cos(alpha)
    ve = SPEED_MPS * math.sin(alpha)
    curvature = vn * vn / (rm + ALT_M) + ve * ve / (rn + ALT_M)
    sphi, cphi = math.sin(phi), math.cos(phi)
    cor_n = 2.0 * OMEGA * sphi * ve
    cor_e = -2.0 * OMEGA * sphi * vn
    cor_d = 2.0 * OMEGA * cphi * ve
    g = gravity(phi, ALT_M)
    return cor_n, cor_e, curvature + cor_d - g


def attitude(alpha, beta):
    """Hamilton quaternion, body FLU to NED, for track azimuth and bank.

    Level FLU at azimuth alpha is a 180 deg roll of the heading-aligned
    FRD frame, which is q = (0, cos(a/2), sin(a/2), 0). Bank beta is a
    right-wing-down rotation about the nose, composed on the right.
    """
    c, s = math.cos(alpha * 0.5), math.sin(alpha * 0.5)
    cb, sb = math.cos(beta * 0.5), math.sin(beta * 0.5)
    return (-c * sb, c * cb, s * cb, -s * sb)


def qmul(a, b):
    aw, ax, ay, az = a
    bw, bx, by, bz = b
    return (
        aw * bw - ax * bx - ay * by - az * bz,
        aw * bx + ax * bw + ay * bz - az * by,
        aw * by - ax * bz + ay * bw + az * bx,
        aw * bz + ax * by - ay * bx + az * bw,
    )


def qconj(q):
    w, x, y, z = q
    return (w, -x, -y, -z)


def unbanked_force(phi, alpha):
    fn, fe, fd = specific_force_ned(phi, alpha)
    ca, sa = math.cos(alpha), math.sin(alpha)
    fx = ca * fn + sa * fe
    fy = sa * fn - ca * fe
    fz = -fd
    return fx, fy, fz


def coordinated_bank(phi, alpha):
    """Bank that puts specific force in the body XZ plane. Positive = right wing down."""
    _fx, fy, fz = unbanked_force(phi, alpha)
    return math.atan2(-fy, fz)


def ned_basis(phi, lam):
    """North, east, and down unit vectors expressed in ECEF."""
    sphi, cphi = math.sin(phi), math.cos(phi)
    slam, clam = math.sin(lam), math.cos(lam)
    north = (-sphi * clam, -sphi * slam, cphi)
    east = (-slam, clam, 0.0)
    down = (-cphi * clam, -cphi * slam, -sphi)
    return north, east, down


def mat_to_quat(col0, col1, col2):
    """Hamilton quaternion whose rotation matrix has these columns."""
    m00, m10, m20 = col0
    m01, m11, m21 = col1
    m02, m12, m22 = col2
    trace = m00 + m11 + m22
    if trace > 0.0:
        s = math.sqrt(trace + 1.0) * 2.0
        w, x = 0.25 * s, (m21 - m12) / s
        y, z = (m02 - m20) / s, (m10 - m01) / s
    elif m00 > m11 and m00 > m22:
        s = math.sqrt(1.0 + m00 - m11 - m22) * 2.0
        w, x = (m21 - m12) / s, 0.25 * s
        y, z = (m01 + m10) / s, (m02 + m20) / s
    elif m11 > m22:
        s = math.sqrt(1.0 + m11 - m00 - m22) * 2.0
        w, x = (m02 - m20) / s, (m01 + m10) / s
        y, z = 0.25 * s, (m12 + m21) / s
    else:
        s = math.sqrt(1.0 + m22 - m00 - m11) * 2.0
        w, x = (m10 - m01) / s, (m02 + m20) / s
        y, z = (m12 + m21) / s, 0.25 * s
    n = math.sqrt(w * w + x * x + y * y + z * z)
    return (w / n, x / n, y / n, z / n)


def qrot(q, v):
    return qmul(qmul(q, (0.0, v[0], v[1], v[2])), qconj(q))[1:]


def level_velocity(phi, alpha):
    """North and east rates (m/s) of the constant-height geodesic.

    alpha is the ellipsoid-geodesic azimuth. At altitude the meridian and
    prime-vertical radii stretch by different factors, so the ground track
    is not exactly that azimuth. The returned components are d(north)/dt
    and d(east)/dt of the ECEF position, and their magnitude is SPEED_MPS.
    """
    rm, rn = radii(phi)
    ca, sa = math.cos(alpha), math.sin(alpha)
    cm = (rm + ALT_M) / rm
    cn = (rn + ALT_M) / rn
    scale = math.hypot(cm * ca, cn * sa)
    dsdt = SPEED_MPS / scale
    return cm * ca * dsdt, cn * sa * dsdt, dsdt, rm, rn


def level_accel(phi, alpha):
    """NED components of d^2(r_ecef)/dt^2 for this cruise."""
    vn, ve, dsdt, rm, rn = level_velocity(phi, alpha)
    ca, sa = math.cos(alpha), math.sin(alpha)
    sphi, cphi = math.sin(phi), math.cos(phi)
    w = 1.0 - E2 * sphi * sphi
    drm = rm * 3.0 * E2 * sphi * cphi / w
    drn = rn * E2 * sphi * cphi / w
    phi_dot = dsdt * ca / rm
    alpha_dot = dsdt * sa * math.tan(phi) / rn
    cm = (rm + ALT_M) / rm
    cn = (rn + ALT_M) / rn
    dcm = -ALT_M / (rm * rm) * drm * phi_dot
    dcn = -ALT_M / (rn * rn) * drn * phi_dot
    u, wv = cm * ca, cn * sa
    scale = math.hypot(u, wv)
    du = dcm * ca - cm * sa * alpha_dot
    dw = dcn * sa + cn * ca * alpha_dot
    dscale = (u * du + wv * dw) / scale
    ddsdt = -SPEED_MPS * dscale / (scale * scale)
    dvn = dcm * ca * dsdt - cm * sa * alpha_dot * dsdt + cm * ca * ddsdt
    dve = dcn * sa * dsdt + cn * ca * alpha_dot * dsdt + cn * sa * ddsdt
    rho_n, rho_m = rn + ALT_M, rm + ALT_M
    w_d = -ve * math.tan(phi) / rho_n
    a_n = dvn - w_d * ve
    a_e = dve + w_d * vn
    a_d = ve * ve / rho_n + vn * vn / rho_m
    return a_n, a_e, a_d


def ecef_kinematics(phi, lam, alpha):
    """ECEF velocity, kinematic acceleration, and the ground-track azimuth."""
    vn, ve, _dsdt, _rm, _rn = level_velocity(phi, alpha)
    a_n, a_e, a_d = level_accel(phi, alpha)
    north, east, down = ned_basis(phi, lam)
    vel = tuple(vn * north[i] + ve * east[i] for i in range(3))
    acc = tuple(a_n * north[i] + a_e * east[i] + a_d * down[i] for i in range(3))
    heading = math.atan2(ve, vn)
    return vel, acc, north, east, down, heading


def state_at(t, azi0, ss, tt):
    s = surface_distance_at(t, ss, tt)
    lat, lon, alpha = geodesic_direct(START_LAT, START_LON, azi0, s)
    return {
        "lat": lat,
        "lon": lon,
        "phi": math.radians(lat),
        "alpha": alpha,
    }


def sample(t, azi0, ss, tt):
    st = state_at(t, azi0, ss, tt)
    lam = math.radians(st["lon"])
    pos = geodetic_to_ecef(st["lat"], st["lon"], ALT_M)
    vel, acc, north, east, down, heading = ecef_kinematics(st["phi"], lam, st["alpha"])
    # Nose along the ground track. Bank cancels lateral specific force.
    quat = qmul(mat_to_quat(north, east, down), attitude(heading, coordinated_bank(st["phi"], heading)))
    return {
        "t_s": t,
        "x_m": pos[0], "y_m": pos[1], "z_m": pos[2],
        "vx_mps": vel[0], "vy_mps": vel[1], "vz_mps": vel[2],
        "ax_mps2": acc[0], "ay_mps2": acc[1], "az_mps2": acc[2],
        "qw": quat[0], "qx": quat[1], "qy": quat[2], "qz": quat[3],
        "lat": st["lat"], "lon": st["lon"],
    }


def align_quaternions(records):
    """Keep the Hamilton double cover from flipping between samples."""
    for i in range(1, len(records)):
        prev, cur = records[i - 1], records[i]
        dot = prev["qw"] * cur["qw"] + prev["qx"] * cur["qx"] + prev["qy"] * cur["qy"] + prev["qz"] * cur["qz"]
        if dot < 0.0:
            cur["qw"], cur["qx"], cur["qy"], cur["qz"] = -cur["qw"], -cur["qx"], -cur["qy"], -cur["qz"]


def check_geodesic():
    """Direct then inverse must recover this route's distance and azimuth."""
    s, azi1, _ = geodesic_inverse(START_LAT, START_LON, TOKYO_LAT, TOKYO_LON)
    lat2, lon2, _ = geodesic_direct(START_LAT, START_LON, azi1, s)
    if abs(lat2 - TOKYO_LAT) > 1e-10 or abs(lon2 - TOKYO_LON) > 1e-10:
        raise AssertionError(f"geodesic direct missed Tokyo {lat2}, {lon2}")
    back, azi_back, _ = geodesic_inverse(START_LAT, START_LON, lat2, lon2)
    if abs(back - s) > 1e-6:
        raise AssertionError(f"geodesic distance round trip {back} vs {s}")
    if abs(math.atan2(math.sin(azi_back - azi1), math.cos(azi_back - azi1))) > 1e-12:
        raise AssertionError("geodesic azimuth round trip")


def xyz(rec, kind):
    if kind == "p":
        return (rec["x_m"], rec["y_m"], rec["z_m"])
    if kind == "v":
        return (rec["vx_mps"], rec["vy_mps"], rec["vz_mps"])
    return (rec["ax_mps2"], rec["ay_mps2"], rec["az_mps2"])


def q_of(rec):
    return (rec["qw"], rec["qx"], rec["qy"], rec["qz"])


def check_state(azi0, records):
    """Position, velocity, acceleration, and orientation agree in ECEF."""
    start_ll = geodetic_to_ecef(START_LAT, START_LON, ALT_M)
    if math.dist(xyz(records[0], "p"), start_ll) > 1e-6:
        raise AssertionError("departure ECEF does not match the geodetic start")
    tokyo = geodetic_to_ecef(TOKYO_LAT, TOKYO_LON, ALT_M)
    if math.dist(xyz(records[-1], "p"), tokyo) > 1e-3:
        raise AssertionError(f"missed Tokyo by {math.dist(xyz(records[-1], 'p'), tokyo)} m")

    for index in (len(records) // 2,):
        rec = records[index]
        speed = math.dist(xyz(rec, "v"), (0.0, 0.0, 0.0))
        if abs(speed - SPEED_MPS) > 1e-6:
            raise AssertionError(f"ECEF speed {speed}")
        nrm = math.sqrt(sum(c * c for c in q_of(rec)))
        if abs(nrm - 1.0) > 1e-12:
            raise AssertionError(f"quaternion norm {nrm}")
        nose = qrot(q_of(rec), (1.0, 0.0, 0.0))
        vel = xyz(rec, "v")
        along = sum(a * b for a, b in zip(nose, vel)) / SPEED_MPS
        if abs(along - 1.0) > 1e-8:
            raise AssertionError(f"nose is not along ECEF velocity ({along})")
        # Kinematic acceleration points inward, along the ellipsoid normal.
        inward = sum(a * b for a, b in zip(xyz(rec, "a"), xyz(rec, "p")))
        if inward >= 0.0:
            raise AssertionError("ECEF acceleration is not inward")
        amag = math.dist(xyz(rec, "a"), (0.0, 0.0, 0.0))
        if not (0.005 < amag < 0.01):
            raise AssertionError(f"ECEF acceleration magnitude {amag}")

    # Central differences of the stored samples must reproduce v and a.
    # Stay on the uniform 10 Hz grid; the final sample closes the geodesic
    # and is not one period later.
    step = int(HZ)
    last = len(records) - 1
    if abs(records[last]["t_s"] * HZ - round(records[last]["t_s"] * HZ)) > 1e-6:
        last -= 1
    for index in (step, len(records) // 2, last - step):
        dt = records[index + step]["t_s"] - records[index - step]["t_s"]
        v_fd = tuple(
            (b - a) / dt for a, b in zip(xyz(records[index - step], "p"), xyz(records[index + step], "p"))
        )
        a_fd = tuple(
            (b - a) / dt for a, b in zip(xyz(records[index - step], "v"), xyz(records[index + step], "v"))
        )
        if math.dist(v_fd, xyz(records[index], "v")) > 1e-5:
            raise AssertionError(
                f"velocity disagrees with d(position)/dt by "
                f"{math.dist(v_fd, xyz(records[index], 'v'))} at {records[index]['t_s']}"
            )
        if math.dist(a_fd, xyz(records[index], "a")) > 1e-7:
            raise AssertionError(
                f"acceleration disagrees with d(velocity)/dt by "
                f"{math.dist(a_fd, xyz(records[index], 'a'))} at {records[index]['t_s']}"
            )

    lat2, lon2, _ = geodesic_direct(START_LAT, START_LON, azi0, 1.0)
    scale = height_scale(math.radians(START_LAT), azi0)
    ecef_step = math.dist(geodetic_to_ecef(START_LAT, START_LON, ALT_M), geodetic_to_ecef(lat2, lon2, ALT_M))
    if abs(ecef_step - scale) > 1e-4:
        raise AssertionError(f"height scale {scale} vs ECEF step {ecef_step}")


def zigzag(n):
    return (n << 1) ^ (n >> 63)


def varint(n):
    z = zigzag(n)
    out = bytearray()
    while True:
        byte = z & 0x7F
        z >>= 7
        if z:
            out.append(byte | 0x80)
        else:
            out.append(byte)
            return bytes(out)


def avro_string(text):
    raw = text.encode("utf-8")
    return varint(len(raw)) + raw


def avro_bytes(raw):
    return varint(len(raw)) + raw


def write_avro(path, records):
    meta = bytearray()
    entries = {
        "avro.codec": b"deflate",
        "avro.schema": SCHEMA.encode("utf-8"),
    }
    meta += varint(len(entries))
    for key, val in entries.items():
        meta += avro_string(key) + avro_bytes(val)
    meta += varint(0)

    chunks = []
    block = bytearray()
    count = 0
    block_records = 4000

    def flush():
        nonlocal block, count
        if count == 0:
            return
        payload = zlib.compress(block)
        chunks.append(varint(count) + varint(len(payload)) + payload + SYNC)
        block = bytearray()
        count = 0

    for rec in records:
        for name in FIELDS:
            block += struct.pack("<d", rec[name])
        count += 1
        if count == block_records:
            flush()
    flush()

    with open(path, "wb") as fh:
        fh.write(b"Obj\x01")
        fh.write(meta)
        fh.write(SYNC)
        for chunk in chunks:
            fh.write(chunk)


def read_avro_check(path, records):
    with open(path, "rb") as fh:
        blob = fh.read()
    if blob[:4] != b"Obj\x01":
        raise AssertionError("bad avro magic")
    if blob[4 + _header_size(blob) : 4 + _header_size(blob) + 16] != SYNC:
        raise AssertionError("sync marker missing after header")
    # Walk blocks and compare the first and last record.
    pos = 4 + _header_size(blob) + 16
    decoded = []
    while pos < len(blob):
        count, pos = _read_long(blob, pos)
        size, pos = _read_long(blob, pos)
        raw = zlib.decompress(blob[pos : pos + size])
        pos += size
        if blob[pos : pos + 16] != SYNC:
            raise AssertionError("block sync mismatch")
        pos += 16
        if len(raw) != count * 8 * len(FIELDS):
            raise AssertionError("block length does not match the schema")
        for i in range(count):
            vals = struct.unpack_from("<" + "d" * len(FIELDS), raw, i * 8 * len(FIELDS))
            decoded.append(vals)
    if len(decoded) != len(records):
        raise AssertionError(f"read {len(decoded)} records, wrote {len(records)}")
    for index in (0, len(records) // 2, -1):
        for got, name in zip(decoded[index], FIELDS):
            if abs(got - records[index][name]) > 1e-12:
                raise AssertionError(f"{name} mismatch on read-back")


def _read_long(blob, pos):
    z = 0
    shift = 0
    while True:
        byte = blob[pos]
        pos += 1
        z |= (byte & 0x7F) << shift
        if not byte & 0x80:
            break
        shift += 7
    n = (z >> 1) ^ -(z & 1)
    return n, pos


def _header_size(blob):
    """Byte length of the metadata map, not including magic or sync."""
    count, pos = _read_long(blob, 4)
    for _ in range(count):
        klen, pos = _read_long(blob, pos)
        pos += klen
        vlen, pos = _read_long(blob, pos)
        pos += vlen
    end, pos = _read_long(blob, pos)
    if end != 0:
        raise AssertionError("metadata map was not terminated")
    return pos - 4


def main():
    check_geodesic()
    distance, azi0, _azi_end = geodesic_inverse(START_LAT, START_LON, TOKYO_LAT, TOKYO_LON)
    ss, tt = build_time_table(distance, azi0)
    duration = tt[-1]

    n = int(math.floor(duration * HZ))
    times = [i / HZ for i in range(n + 1)]
    if times[-1] < duration:
        times.append(duration)
    records = [sample(t, azi0, ss, tt) for t in times]
    align_quaternions(records)
    check_state(azi0, records)

    path = __file__.replace("write_japan_trajectory.py", "trajectory.avro")
    write_avro(path, records)
    read_avro_check(path, records)

    mid = records[len(records) // 2]
    end = records[-1]
    print(f"wrote {path}")
    print(f"samples {len(records)}  hz {HZ:g}  duration {duration:.3f} s  distance {distance:.3f} m")
    for label, rec in (("t0 ", records[0]), ("mid", mid), ("end", end)):
        speed = math.dist(xyz(rec, "v"), (0.0, 0.0, 0.0))
        amag = math.dist(xyz(rec, "a"), (0.0, 0.0, 0.0))
        print(
            f"{label}  r {rec['x_m']:.3f} {rec['y_m']:.3f} {rec['z_m']:.3f}"
            f"  |v| {speed:.6f}  |a| {amag:.6f}"
        )


if __name__ == "__main__":
    main()

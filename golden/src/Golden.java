// The reference side of `docs/design.md` D5: reads the golden inputs with the patched
// BRouter v1.7.10 (build.sh) and writes what the Dart port must reproduce.
// FORMAT.md describes every output byte for byte.
//
//   decode <tile.rd5> <out-dir>
//       layer 1: one digest per micro-cache, plus the distinct way and node
//       descriptions the tile holds (the input of layer 2)
//   rules <lookups.dat> <profile.brf> <ways.hex> <nodes.hex> <out.tsv>
//       layer 2: the profile's built-in variables for each description
//   ops <lookups.dat> <ops.brf> <ways.hex> <nodes.hex> <out.tsv>
//       layer 2 extra: per-variable CRC32 of a profile's values over all
//       descriptions, for operators the real profiles do not use
//   dump <tile.rd5> <lonIdx> <latIdx>
//       one micro-cache as text, for finding where a digest differs

import java.io.BufferedWriter;
import java.io.ByteArrayOutputStream;
import java.io.DataOutputStream;
import java.io.File;
import java.io.IOException;
import java.io.PrintStream;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.security.MessageDigest;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HexFormat;
import java.util.List;
import java.util.TreeSet;

import btools.codec.DataBuffers;
import btools.codec.MicroCache;
import btools.codec.MicroCache2;
import btools.expressions.BExpressionContextNode;
import btools.expressions.BExpressionContextWay;
import btools.expressions.BExpressionMetaData;
import btools.mapaccess.OsmFile;
import btools.router.OsmNodeNamed;
import btools.router.OsmPathElement;
import btools.router.OsmTrack;
import btools.router.RoutingContext;
import btools.router.RoutingEngine;
import btools.mapaccess.PhysicalFile;
import btools.util.BitCoderContext;
import btools.util.ByteDataWriter;
import btools.util.CheapAngleMeter;
import btools.util.CheapRuler;
import btools.util.Crc32;
import btools.util.IByteArrayUnifier;

public class Golden {
  static final HexFormat HEX = HexFormat.of();
  // Copies instead of unifying, so nothing depends on a cache.
  static final IByteArrayUnifier COPY = (ab, off, len) -> java.util.Arrays.copyOfRange(ab, off, off + len);

  public static void main(String[] args) throws Exception {
    switch (args[0]) {
      case "decode" -> decode(new File(args[1]), Path.of(args[2]));
      case "rules" -> rules(new File(args[1]), new File(args[2]), Path.of(args[3]), Path.of(args[4]), Path.of(args[5]));
      case "ops" -> ops(new File(args[1]), new File(args[2]), Path.of(args[3]), Path.of(args[4]), Path.of(args[5]));
      case "dump" -> dump(new File(args[1]), Integer.parseInt(args[2]), Integer.parseInt(args[3]));
      case "util" -> util(Path.of(args[1]));
      case "routes" -> routes(Path.of(args[1]), new File(args[2]), Path.of(args[3]));
      case "bench" -> bench(Path.of(args[1]), new File(args[2]), Integer.parseInt(args[3]));
      default -> throw new IllegalArgumentException(args[0]);
    }
  }

  interface CacheVisitor {
    void visit(int lonIdx, int latIdx, MicroCache2 mc) throws Exception;
  }

  // Every micro-cache of the tile, one-degree square by square (lon, then lat)
  // and lonIdx then latIdx within each, decoded with
  // no way validator (keep every way) and no waypoint matcher.
  static void eachCache(File rd5, CacheVisitor v) throws Exception {
    DataBuffers buffers = new DataBuffers();
    PhysicalFile pf = new PhysicalFile(rd5, buffers, -1, -1);
    try {
      int div = pf.divisor;
      String name = rd5.getName(); // E120_N20.rd5
      int lon = Integer.parseInt(name.substring(1, name.indexOf('_'))) * (name.charAt(0) == 'W' ? -1 : 1);
      String latPart = name.substring(name.indexOf('_') + 1, name.indexOf('.'));
      int lat = Integer.parseInt(latPart.substring(1)) * (latPart.charAt(0) == 'S' ? -1 : 1);
      for (int dlon = 0; dlon < 5; dlon++) {
        for (int dlat = 0; dlat < 5; dlat++) {
          int lonDegree = lon + 180 + dlon;
          int latDegree = lat + 90 + dlat;
          OsmFile osmf = new OsmFile(pf, lonDegree, latDegree, buffers);
          if (!osmf.hasData()) continue;
          for (int i = 0; i < div; i++) {
            for (int j = 0; j < div; j++) {
              int lonIdx = lonDegree * div + i;
              int latIdx = latDegree * div + j;
              MicroCache mc = osmf.createMicroCache(lonIdx, latIdx, buffers, null, null, true, null);
              if (mc instanceof MicroCache2 mc2 && mc2.getSize() > 0) v.visit(lonIdx, latIdx, mc2);
            }
          }
        }
      }
    } finally {
      pf.close();
    }
  }

  // One node as the decoder yields it: FORMAT.md "Node record".
  record Link(int lon, int lat, boolean reverse, byte[] description, byte[] geometry) {}

  record Node(int ilon, int ilat, List<int[]> restrictions, short selev, byte[] description, List<Link> links) {}

  static List<Node> nodes(MicroCache2 mc) {
    List<Node> out = new ArrayList<>();
    int size = mc.getSize();
    long[] ids = new long[size];
    for (int i = 0; i < size; i++) ids[i] = mc.getIdForIndex(i);
    for (long id : ids) {
      if (!mc.getAndClear(id)) throw new IllegalStateException("node not found " + id);
      int ilon = (int) (id >> 32);
      int ilat = (int) (id & 0xffffffffL);
      List<int[]> trs = new ArrayList<>();
      while (mc.readBoolean()) {
        int exceptions = mc.readShort();
        int positive = mc.readBoolean() ? 1 : 0;
        trs.add(new int[] {exceptions, positive, mc.readInt(), mc.readInt(), mc.readInt(), mc.readInt()});
      }
      short selev = mc.readShort();
      int nodeDescSize = mc.readVarLengthUnsigned();
      byte[] nodeDesc = nodeDescSize == 0 ? new byte[0] : mc.readUnified(nodeDescSize, COPY);
      List<Link> links = new ArrayList<>();
      while (mc.hasMoreData()) {
        int end = mc.getEndPointer();
        int linklon = ilon + mc.readVarLengthSigned();
        int linklat = ilat + mc.readVarLengthSigned();
        int sizecode = mc.readVarLengthUnsigned();
        int descSize = sizecode >> 1;
        byte[] desc = descSize > 0 ? mc.readUnified(descSize, COPY) : new byte[0];
        byte[] geometry = mc.readDataUntil(end);
        links.add(new Link(linklon, linklat, (sizecode & 1) != 0, desc, geometry == null ? new byte[0] : geometry));
      }
      out.add(new Node(ilon, ilat, trs, selev, nodeDesc, links));
    }
    return out;
  }

  static byte[] canonical(int lonIdx, int latIdx, List<Node> nodes) throws IOException {
    ByteArrayOutputStream bytes = new ByteArrayOutputStream();
    DataOutputStream o = new DataOutputStream(bytes);
    o.writeInt(lonIdx);
    o.writeInt(latIdx);
    o.writeInt(nodes.size());
    for (Node n : nodes) {
      o.writeInt(n.ilon);
      o.writeInt(n.ilat);
      o.writeInt(n.restrictions.size());
      for (int[] tr : n.restrictions) {
        o.writeShort(tr[0]);
        o.writeByte(tr[1]);
        for (int k = 2; k < 6; k++) o.writeInt(tr[k]);
      }
      o.writeShort(n.selev);
      bytesField(o, n.description);
      o.writeInt(n.links.size());
      for (Link l : n.links) {
        o.writeInt(l.lon);
        o.writeInt(l.lat);
        o.writeByte(l.reverse ? 1 : 0);
        bytesField(o, l.description);
        bytesField(o, l.geometry);
      }
    }
    return bytes.toByteArray();
  }

  static void bytesField(DataOutputStream o, byte[] b) throws IOException {
    o.writeInt(b.length);
    o.write(b);
  }

  static void decode(File rd5, Path outDir) throws Exception {
    Files.createDirectories(outDir);
    String base = rd5.getName().replace(".rd5", "");
    TreeSet<String> ways = new TreeSet<>();
    TreeSet<String> nodeDescs = new TreeSet<>();
    MessageDigest sha = MessageDigest.getInstance("SHA-256");
    try (BufferedWriter w = Files.newBufferedWriter(outDir.resolve(base + ".decode.tsv"))) {
      eachCache(rd5, (lonIdx, latIdx, mc) -> {
        List<Node> nodes = nodes(mc);
        for (Node n : nodes) {
          if (n.description.length > 0) nodeDescs.add(HEX.formatHex(n.description));
          for (Link l : n.links) if (l.description.length > 0) ways.add(HEX.formatHex(l.description));
        }
        byte[] digest = sha.digest(canonical(lonIdx, latIdx, nodes));
        w.write(lonIdx + "\t" + latIdx + "\t" + nodes.size() + "\t" + HEX.formatHex(digest, 0, 16) + "\n");
      });
    }
    Files.write(outDir.resolve(base + ".ways.hex"), ways, StandardCharsets.US_ASCII);
    Files.write(outDir.resolve(base + ".nodes.hex"), nodeDescs, StandardCharsets.US_ASCII);
  }

  static void dump(File rd5, int wantLon, int wantLat) throws Exception {
    PrintStream out = System.out;
    eachCache(rd5, (lonIdx, latIdx, mc) -> {
      if (lonIdx != wantLon || latIdx != wantLat) return;
      for (Node n : nodes(mc)) {
        out.println("node " + n.ilon + " " + n.ilat + " selev=" + n.selev + " desc=" + HEX.formatHex(n.description));
        for (int[] tr : n.restrictions) out.println("  restriction " + java.util.Arrays.toString(tr));
        for (Link l : n.links) {
          out.println("  link " + l.lon + " " + l.lat + (l.reverse ? " reverse" : "") + " desc=" + HEX.formatHex(l.description) + " geom=" + HEX.formatHex(l.geometry));
        }
      }
    });
  }

  // Layer 2: FORMAT.md "Rules table".
  static void rules(File lookups, File profile, Path waysHex, Path nodesHex, Path out) throws Exception {
    BExpressionMetaData meta = new BExpressionMetaData();
    // hash size 0: no result cache, every line is evaluated from scratch
    BExpressionContextWay way = new BExpressionContextWay(0, meta);
    BExpressionContextNode node = new BExpressionContextNode(0, meta);
    node.setForeignContext(way);
    meta.readMetaData(lookups);
    way.parseFile(profile, "global", new HashMap<>());
    node.parseFile(profile, "global", new HashMap<>());
    try (BufferedWriter w = Files.newBufferedWriter(out)) {
      for (String hex : Files.readAllLines(waysHex)) {
        byte[] ab = HEX.parseHex(hex);
        StringBuilder sb = new StringBuilder("way\t").append(hex);
        for (boolean inverse : new boolean[] {false, true}) {
          way.evaluate(inverse, ab);
          for (int i = 0; i < 20; i++) sb.append('\t').append(floatHex(way.getBuildInVariable(i)));
        }
        w.write(sb.append('\n').toString());
      }
      for (String hex : Files.readAllLines(nodesHex)) {
        byte[] ab = HEX.parseHex(hex);
        // The node context reads nodeaccessgranted from this flag, which
        // StdPath sets from the way it arrives by: record both.
        StringBuilder sb = new StringBuilder("node\t").append(hex);
        for (boolean granted : new boolean[] {false, true}) {
          node.evaluate(granted, ab);
          sb.append('\t').append(floatHex(node.getBuildInVariable(0)));
        }
        w.write(sb.append('\n').toString());
      }
    }
  }

  static final String[] WAY_VARIABLES = {"costfactor", "turncost", "uphillcostfactor", "downhillcostfactor",
    "initialcost", "nodeaccessgranted", "initialclassifier", "trafficsourcedensity", "istrafficbackbone",
    "priorityclassifier", "classifiermask", "maxspeed", "uphillcost", "downhillcost", "uphillcutoff",
    "downhillcutoff", "uphillmaxslope", "downhillmaxslope", "uphillmaxslopecost", "downhillmaxslopecost"};

  // Layer 2 extra: FORMAT.md 「規則沒用到的運算子」. Contexts set up as in rules;
  // one CRC32 per variable over its raw float bits, big-endian, in input
  // order.
  static void ops(File lookups, File profile, Path waysHex, Path nodesHex, Path out) throws Exception {
    BExpressionMetaData meta = new BExpressionMetaData();
    BExpressionContextWay way = new BExpressionContextWay(0, meta);
    BExpressionContextNode node = new BExpressionContextNode(0, meta);
    node.setForeignContext(way);
    meta.readMetaData(lookups);
    way.parseFile(profile, "global", new HashMap<>());
    node.parseFile(profile, "global", new HashMap<>());
    List<String> ways = Files.readAllLines(waysHex);
    List<String> nodes = Files.readAllLines(nodesHex);
    ByteArrayOutputStream[] wayBits = new ByteArrayOutputStream[40];
    for (int i = 0; i < 40; i++) wayBits[i] = new ByteArrayOutputStream();
    for (String hex : ways) {
      byte[] ab = HEX.parseHex(hex);
      for (int d = 0; d < 2; d++) {
        way.evaluate(d == 1, ab);
        for (int v = 0; v < 20; v++) new DataOutputStream(wayBits[20 * d + v]).writeInt(Float.floatToRawIntBits(way.getBuildInVariable(v)));
      }
    }
    ByteArrayOutputStream[] nodeBits = {new ByteArrayOutputStream(), new ByteArrayOutputStream()};
    for (String hex : nodes) {
      byte[] ab = HEX.parseHex(hex);
      for (int g = 0; g < 2; g++) {
        node.evaluate(g == 1, ab);
        new DataOutputStream(nodeBits[g]).writeInt(Float.floatToRawIntBits(node.getBuildInVariable(0)));
      }
    }
    try (BufferedWriter w = Files.newBufferedWriter(out)) {
      for (int i = 0; i < 40; i++) {
        w.write("way\t" + (i < 20 ? "forward" : "reverse") + "\t" + WAY_VARIABLES[i % 20] + "\t" + crcHex(wayBits[i].toByteArray()) + "\n");
      }
      for (int g = 0; g < 2; g++) {
        w.write("node\t" + (g == 1) + "\tinitialcost\t" + crcHex(nodeBits[g].toByteArray()) + "\n");
      }
    }
  }

  static String crcHex(byte[] b) {
    return String.format("%08x", Crc32.crc(b, 0, b.length));
  }

  static String floatHex(float f) {
    return String.format("%08x", Float.floatToRawIntBits(f));
  }

  // Layer 0: FORMAT.md "Util table". Inputs are written next to the results,
  // so the Dart side needs no copy of java.util.Random.
  static void util(Path out) throws Exception {
    java.util.Random rnd = new java.util.Random(20261123L);
    double[] specials = {0.0, -0.0, 1.0, -1.0, Math.PI / 4, -Math.PI / 4, Math.PI / 2, -Math.PI / 2, Math.PI,
      3 * Math.PI / 4, 2 * Math.PI, 1e-9, 1e-300, 0.3, 0.78125, 0.5 * Math.log(2), 1.5 * Math.log(2),
      709.78, 709.79, -745.13, -745.14, 1e6, -1e6, 823549.6656, Double.NaN,
      Double.POSITIVE_INFINITY, Double.NEGATIVE_INFINITY, Double.MIN_VALUE, Double.MAX_VALUE};
    try (BufferedWriter w = Files.newBufferedWriter(out)) {
      // trigonometry on every latitude CheapRuler caches, then random, then edges
      List<Double> trig = new ArrayList<>();
      for (int i = 0; i < 1800; i++) trig.add(CheapRuler.DEG_TO_RAD * ((i * 100000 + 50000) * 1e-6 - 90));
      for (int i = 0; i < 5000; i++) trig.add((rnd.nextDouble() - 0.5) * 40);
      for (int i = 0; i < 200; i++) trig.add((i - 100) * Math.PI / 2 + (rnd.nextDouble() - 0.5) * 1e-6);
      for (double d : specials) trig.add(d);
      for (double x : trig) {
        w.write("sin\t" + dbl(x) + "\t" + dbl(StrictMath.sin(x)) + "\n");
        w.write("cos\t" + dbl(x) + "\t" + dbl(StrictMath.cos(x)) + "\n");
      }
      List<Double> exps = new ArrayList<>();
      for (int i = 0; i < 5000; i++) exps.add(-rnd.nextDouble() * 50);
      for (int i = 0; i < 1000; i++) exps.add((rnd.nextDouble() - 0.5) * 1500);
      for (double d : specials) exps.add(d);
      for (double x : exps) w.write("exp\t" + dbl(x) + "\t" + dbl(StrictMath.exp(x)) + "\n");
      for (int i = 0; i < 5000; i++) {
        double y = rnd.nextInt(2000001) - 1000000, x = rnd.nextInt(2000001) - 1000000;
        if (i % 2 == 1) { y = (rnd.nextDouble() - 0.5) * 10; x = (rnd.nextDouble() - 0.5) * 10; }
        w.write("atan2\t" + dbl(y) + "\t" + dbl(x) + "\t" + dbl(StrictMath.atan2(y, x)) + "\n");
      }
      for (double y : specials) for (double x : specials) {
        w.write("atan2\t" + dbl(y) + "\t" + dbl(x) + "\t" + dbl(StrictMath.atan2(y, x)) + "\n");
      }
      // CheapRuler and CheapAngleMeter on points around Taiwan
      int[] p = new int[6];
      CheapAngleMeter cam = new CheapAngleMeter();
      for (int i = 0; i < 5000; i++) {
        for (int k = 0; k < 6; k += 2) {
          p[k] = 300000000 + rnd.nextInt(5000000);
          p[k + 1] = 110000000 + rnd.nextInt(5000000);
        }
        if (i % 3 == 0) { p[2] = p[0] + rnd.nextInt(201) - 100; p[3] = p[1] + rnd.nextInt(201) - 100; }
        if (i % 7 == 0) { p[4] = p[2]; p[5] = p[3]; }
        double dist = rnd.nextDouble() * 5000, ang = (rnd.nextDouble() - 0.5) * 1000;
        int[] d = CheapRuler.destination(p[0], p[1], dist, ang);
        double a = cam.calcAngle(p[0], p[1], p[2], p[3], p[4], p[5]);
        w.write("geo\t" + p[0] + "\t" + p[1] + "\t" + p[2] + "\t" + p[3] + "\t" + p[4] + "\t" + p[5] + "\t" + dbl(dist) + "\t" + dbl(ang)
          + "\t" + dbl(CheapRuler.distance(p[0], p[1], p[2], p[3])) + "\t" + d[0] + "\t" + d[1]
          + "\t" + dbl(a) + "\t" + dbl(cam.getCosAngle())
          + "\t" + dbl(CheapAngleMeter.getDirection(p[0], p[1], p[2], p[3])) + "\n");
      }
      for (int i = 0; i < 2000; i++) {
        double b1 = (rnd.nextDouble() - 0.5) * 2000, b2 = (rnd.nextDouble() - 0.5) * 2000;
        w.write("dir\t" + dbl(b1) + "\t" + dbl(b2) + "\t" + dbl(CheapAngleMeter.getDifferenceFromDirection(b1, b2)) + "\t" + dbl(CheapAngleMeter.normalize(b1)) + "\n");
      }
      // CRC over random arrays
      for (int i = 0; i < 500; i++) {
        byte[] b = new byte[rnd.nextInt(300)];
        rnd.nextBytes(b);
        w.write("crc\t" + HEX.formatHex(b) + "\t" + String.format("%08x", Crc32.crc(b, 0, b.length)) + "\n");
      }
      // var-length ints, signed and unsigned, over the whole int range
      for (int i = 0; i < 3000; i++) {
        int v = i < 1000 ? i - 500 : (i < 2000 ? rnd.nextInt() : rnd.nextInt() >> rnd.nextInt(32));
        ByteDataWriter bw = new ByteDataWriter(new byte[16]);
        bw.writeVarLengthSigned(v);
        bw.writeVarLengthUnsigned(v);
        btools.util.ByteDataReader br = new btools.util.ByteDataReader(bw.toByteArray());
        int s = br.readVarLengthSigned(), u = br.readVarLengthUnsigned();
        w.write("varlen\t" + v + "\t" + HEX.formatHex(bw.toByteArray()) + "\t" + s + "\t" + u + "\n");
      }
      // fixed-width ints, sign extension included: written by the writer,
      // read back by the reader
      for (int i = 0; i < 1000; i++) {
        int iv = i < 100 ? Integer.MIN_VALUE + i : rnd.nextInt();
        long lv = i < 100 ? Long.MIN_VALUE + i : rnd.nextLong();
        int sv = rnd.nextInt(), bv = rnd.nextInt();
        boolean zv = rnd.nextBoolean();
        ByteDataWriter bw = new ByteDataWriter(new byte[16]);
        bw.writeInt(iv); bw.writeLong(lv); bw.writeShort(sv); bw.writeByte(bv); bw.writeBoolean(zv);
        btools.util.ByteDataReader br = new btools.util.ByteDataReader(bw.toByteArray());
        w.write("ints\t" + iv + "\t" + lv + "\t" + sv + "\t" + bv + "\t" + zv + "\t" + HEX.formatHex(bw.toByteArray())
          + "\t" + br.readInt() + "\t" + br.readLong() + "\t" + br.readShort() + "\t" + br.readByte() + "\t" + br.readBoolean() + "\n");
      }
      // size prefix injected after the data, across the 1-, 2- and 3-byte
      // prefix lengths
      int[] injectSizes = {0, 1, 127, 128, 129, 300, 16383, 16384, 16385, 20000};
      for (int i = 0; i < 40; i++) {
        int size = i < injectSizes.length ? injectSizes[i] : rnd.nextInt(20000);
        byte[] lead = new byte[rnd.nextInt(5)];
        byte[] data = new byte[size];
        rnd.nextBytes(lead);
        rnd.nextBytes(data);
        ByteDataWriter bw = new ByteDataWriter(new byte[size + 16]);
        bw.write(lead);
        int at = bw.writeSizePlaceHolder();
        bw.write(data);
        bw.injectSize(at);
        w.write("inject\t" + HEX.formatHex(lead) + "\t" + HEX.formatHex(data) + "\t" + HEX.formatHex(bw.toByteArray()) + "\n");
      }
      // fixed-count reads, plain and bit-reversed, across bytes and refills
      for (int i = 0; i < 300; i++) {
        byte[] b = new byte[64];
        rnd.nextBytes(b);
        BitCoderContext bc = new BitCoderContext(b);
        StringBuilder ops = new StringBuilder();
        int read = 0;
        while (read < 400) {
          boolean rev = rnd.nextBoolean();
          int count = rev ? 1 + rnd.nextInt(32) : rnd.nextInt(25);
          int v = rev ? bc.decodeBitsReverse(count) : bc.decodeBits(count);
          ops.append(rev ? 'r' : 'd').append(count).append(':').append(v).append(',');
          read += count;
        }
        w.write("bitread\t" + HEX.formatHex(b) + "\t" + ops + "\n");
      }
      // bit coder: a script of operations, the bytes it encodes to
      for (int i = 0; i < 300; i++) {
        byte[] buf = new byte[4096];
        BitCoderContext bc = new BitCoderContext(buf);
        StringBuilder ops = new StringBuilder();
        int n = 1 + rnd.nextInt(200);
        for (int k = 0; k < n; k++) {
          int op = rnd.nextInt(3);
          if (op == 0) {
            int v = rnd.nextInt(4) == 0 ? rnd.nextInt(Integer.MAX_VALUE >> rnd.nextInt(31)) : rnd.nextInt(5000);
            bc.encodeVarBits(v);
            ops.append("v").append(v).append(',');
          } else if (op == 1) {
            // below 2^30: for larger max the Java loop never ends (im overflows)
            int max = rnd.nextInt((1 << 30) >> rnd.nextInt(30));
            int v = rnd.nextInt(max + 1);
            bc.encodeBounded(max, v);
            ops.append("b").append(max).append(':').append(v).append(',');
          } else {
            boolean v = rnd.nextBoolean();
            bc.encodeBit(v);
            ops.append(v ? "1," : "0,");
          }
        }
        int len = bc.closeAndGetEncodedLength();
        w.write("bits\t" + ops + "\t" + HEX.formatHex(buf, 0, len) + "\n");
      }
    }
  }

  static String dbl(double d) {
    return String.format("%016x", Double.doubleToRawLongBits(d));
  }

  // Layer 3: FORMAT.md "Route table". Each case, each profile, a fresh
  // engine with the default RoutingContext, as a plain request would get.
  static void routes(Path cases, File inputDir, Path out) throws Exception {
    String[] profiles = {"hiking-mountain", "trekking"};
    try (BufferedWriter w = Files.newBufferedWriter(out)) {
      for (String line : Files.readAllLines(cases)) {
        if (line.isBlank() || line.startsWith("#")) continue;
        String[] f = line.split("\t");
        for (String profile : profiles) {
          List<OsmNodeNamed> wps = new ArrayList<>();
          wps.add(waypoint("from", Double.parseDouble(f[1]), Double.parseDouble(f[2])));
          wps.add(waypoint("to", Double.parseDouble(f[3]), Double.parseDouble(f[4])));
          RoutingContext rc = new RoutingContext();
          rc.localFunction = new File(inputDir, profile + ".brf").getPath();
          RoutingEngine re = new RoutingEngine(null, null, inputDir, wps, rc);
          re.doRun(0);
          StringBuilder sb = new StringBuilder("route\t").append(f[0]).append('\t').append(profile);
          for (OsmNodeNamed n : wps) sb.append('\t').append(n.ilon).append('\t').append(n.ilat);
          OsmTrack t = re.getFoundTrack();
          if (re.getErrorMessage() != null || t == null) {
            sb.append("\terror\t").append(String.valueOf(re.getErrorMessage()).replace('\t', ' ').replace('\n', ' '));
            w.write(sb.append('\n').toString());
            continue;
          }
          sb.append("\tok\t").append(t.distance).append('\t').append(t.ascend).append('\t').append(t.plainAscend)
            .append('\t').append(t.cost).append('\t').append(t.energy).append('\t').append(t.getTotalSeconds())
            .append('\t').append(t.nodes.size());
          w.write(sb.append('\n').toString());
          for (OsmPathElement e : t.nodes) {
            w.write("node\t" + e.getILon() + "\t" + e.getILat() + "\t" + e.getSElev() + "\t" + e.cost
              + "\t" + String.format("%08x", Float.floatToRawIntBits(e.getTime()))
              + "\t" + String.format("%08x", Float.floatToRawIntBits(e.getEnergy())) + "\n");
          }
        }
      }
    }
  }

  static OsmNodeNamed waypoint(String name, double lat, double lon) {
    OsmNodeNamed n = new OsmNodeNamed();
    n.name = name;
    // as RoutingEngineTest and the server turn degrees into integer coordinates
    n.ilon = 180000000 + (int) (lon * 1000000 + 0.5);
    n.ilat = 90000000 + (int) (lat * 1000000 + 0.5);
    return n;
  }

  // `docs/design.md` D6: the same routes as "routes", timed in one JVM, the first round
  // cold and the rest warm, for comparison with bin/bench.dart. quite skips
  // the GPX output, which the Dart side does not have; stdout stays muted for
  // any other print. Both sides time the engine's construction (profile
  // parsing; Java caches the parsed profile, Dart parses it every time)
  // and the routing.
  static void bench(Path cases, File inputDir, int rounds) throws Exception {
    String[] profiles = {"hiking-mountain", "trekking"};
    java.io.PrintStream out = System.out;
    System.setOut(new java.io.PrintStream(java.io.OutputStream.nullOutputStream()));
    try {
      for (int r = 0; r < rounds; r++) {
        long total = 0;
        for (String line : Files.readAllLines(cases)) {
          if (line.isBlank() || line.startsWith("#")) continue;
          String[] f = line.split("\t");
          for (String profile : profiles) {
            List<OsmNodeNamed> wps = new ArrayList<>();
            wps.add(waypoint("from", Double.parseDouble(f[1]), Double.parseDouble(f[2])));
            wps.add(waypoint("to", Double.parseDouble(f[3]), Double.parseDouble(f[4])));
            RoutingContext rc = new RoutingContext();
            rc.localFunction = new File(inputDir, profile + ".brf").getPath();
            long t0 = System.nanoTime();
            RoutingEngine re = new RoutingEngine(null, null, inputDir, wps, rc);
            re.quite = true; // no GPX output, which the Dart side does not have
            re.doRun(0);
            total += System.nanoTime() - t0;
          }
        }
        Runtime rt = Runtime.getRuntime();
        out.println("round " + r + " total " + (total / 1000000) + " ms, heap used " + ((rt.totalMemory() - rt.freeMemory()) >> 20) + " MiB");
      }
    } finally {
      System.setOut(out);
    }
  }
}

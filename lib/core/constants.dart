
import 'package:flutter/material.dart';
import 'theme.dart';

class DetectionClass {
  static const String d0 = 'D0';
  static const String d1 = 'D1';
  static const String d2 = 'D2';
  static const String d3 = 'D3';
  static const String d4 = 'D4';
  static const String d5 = 'D5';
  static const String d6 = 'D6';

  static const List<String> all = [d0, d1, d2, d3, d4, d5, d6];
}

class TreatmentInfo {
  final String severity;
  final String description;
  final List<String> treatment;
  final Color color;
  final Color bgColor;

  const TreatmentInfo({
    required this.severity,
    required this.description,
    required this.treatment,
    required this.color,
    required this.bgColor,
  });
}

final Map<String, TreatmentInfo> treatmentData = {
  DetectionClass.d0: const TreatmentInfo(
    severity: 'Gigi Sehat',
    description: 'Gigi dalam kondisi sehat tanpa tanda-tanda karies. Email gigi utuh dan tidak ada demineralisasi yang terlihat.',
    treatment: [
      'Jaga Kebersihan Oral Hygiene - Sikat gigi 2x sehari dengan teknik yang benar',
      'Gunakan pasta gigi berfluoride untuk perlindungan email',
      'Gunakan dental floss atau sikat interdental setiap hari',
      'Kontrol rutin ke dokter gigi setiap 6 bulan',
      'Batasi konsumsi makanan dan minuman tinggi gula',
    ],
    color: AppColors.d0,
    bgColor: Color(0xFFECFDF5),
  ),
  DetectionClass.d1: const TreatmentInfo(
    severity: 'Lesi Awal (White Spot)',
    description: 'Demineralisasi awal pada email gigi. Terlihat white spot atau perubahan warna putih kapur pada permukaan gigi setelah dikeringkan. Belum ada kavitas atau kerusakan struktural.',
    treatment: [
      'Jaga Kebersihan Oral Hygiene - Tingkatkan frekuensi dan teknik menyikat gigi',
      'Topikal Aplikasi Fluoride - Aplikasi fluoride gel/foam di klinik',
      'Topikal Aplikasi Varnish - Fluoride varnish untuk remineralisasi email',
      'Gunakan pasta gigi dengan kandungan fluoride tinggi (1450-5000 ppm)',
      'Kurangi frekuensi konsumsi gula dan makanan asam',
    ],
    color: AppColors.d1,
    bgColor: Color(0xFFFEF9C3),
  ),
  DetectionClass.d2: const TreatmentInfo(
    severity: 'Lesi Email',
    description: 'Kerusakan terbatas pada lapisan email gigi. Terlihat white/brown spot yang jelas atau perubahan warna pada email. Kavitas minimal, belum mencapai dentin.',
    treatment: [
      'Jaga Kebersihan Oral Hygiene - Perhatikan area yang terkena saat menyikat',
      'Topikal Aplikasi Fluoride - Aplikasi fluoride profesional secara berkala',
      'Topikal Aplikasi Varnish - Fluoride varnish setiap 3-6 bulan',
      'Pertimbangkan infiltrasi resin (Icon) untuk lesi proksimal',
      'Monitoring perkembangan lesi setiap 3 bulan',
    ],
    color: AppColors.d2,
    bgColor: Color(0xFFFFEDD5),
  ),
  DetectionClass.d3: const TreatmentInfo(
    severity: 'Lesi Dentin Awal',
    description: 'Karies sudah menembus email dan mencapai lapisan dentin superfisial. Terlihat kavitas kecil. Mungkin ada sensitivitas terhadap makanan manis atau dingin.',
    treatment: [
      'Jaga Kebersihan Oral Hygiene - Hindari penumpukan plak di area restorasi',
      'Topikal Aplikasi Fluoride - Untuk mencegah karies sekunder',
      'Topikal Aplikasi Varnish - Perlindungan tambahan pasca perawatan',
      'Pertimbangkan restorasi minimal invasif jika kavitas membesar',
      'Kontrol setiap 3 bulan untuk evaluasi perkembangan',
    ],
    color: AppColors.d3,
    bgColor: Color(0xFFFEE2E2),
  ),
  DetectionClass.d4: const TreatmentInfo(
    severity: 'Karies Dentin Dalam',
    description: 'Karies sudah mencapai lebih dari setengah ketebalan dentin. Kavitas yang lebih besar terlihat dengan dentin lunak. Sensitivitas meningkat.',
    treatment: [
      'Jaga Kebersihan Oral Hygiene - Perawatan intensif area sekitar restorasi',
      'Restorasi Composite - Tambalan sewarna gigi dengan bonding',
      'Restorasi GIC (Glass Ionomer Cement) - Alternatif dengan pelepasan fluoride',
      'Aplikasi liner/base untuk perlindungan pulpa',
      'Kontrol pasca restorasi untuk evaluasi sensitivitas',
    ],
    color: AppColors.d4,
    bgColor: Color(0xFFFCE7F3),
  ),
  DetectionClass.d5: const TreatmentInfo(
    severity: 'Karies Mendekati Pulpa',
    description: 'Karies sangat dalam mendekati atau sudah mengenai pulpa. Kemungkinan ada peradangan pulpa (pulpitis). Pasien mungkin mengalami nyeri spontan atau berkepanjangan.',
    treatment: [
      'Jaga Kebersihan Oral Hygiene - Cegah infeksi sekunder',
      'Pulp Capping - Direct/Indirect pulp capping jika pulpa masih vital',
      'Restorasi Composite - Setelah prosedur pulp capping berhasil',
      'Restorasi GIC - Sebagai base sebelum restorasi composite',
      'Evaluasi vitalitas pulpa secara berkala pasca perawatan',
    ],
    color: AppColors.d5,
    bgColor: Color(0xFFEDE9FE),
  ),
  DetectionClass.d6: const TreatmentInfo(
    severity: 'Kerusakan Berat/Nekrosis Pulpa',
    description: 'Kerusakan ekstensif dengan keterlibatan pulpa yang jelas. Mahkota gigi rusak parah. Kemungkinan pulpa sudah nekrosis dengan abses atau infeksi periapical.',
    treatment: [
      'Jaga Kebersihan Oral Hygiene - Penting untuk proses penyembuhan',
      'Root Canal Treatment - Pengangkatan jaringan pulpa yang terinfeksi',
      'Obturasi saluran akar dengan gutta percha',
      'Restorasi pasca endodontik (Post & Core jika diperlukan)',
      'Pertimbangkan mahkota (crown) untuk perlindungan jangka panjang',
    ],
    color: AppColors.d6,
    bgColor: Color(0xFFDBEAFE),
  ),
};

const int kInputSize = 640;
const int kNumClasses = 7;
const int kNumAnchors = 8400;
const double kConfThreshold = 0.45;
const double kIouThreshold = 0.45;


import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import '../../core/theme.dart';
import '../../widgets/action_card.dart';



class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  bool _isPicking = false;

  Future<void> _handleUploadImage() async {
    setState(() => _isPicking = true);
    
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.gallery);
      
      if (image != null) {
        // Navigate to Analysis Detail with the image path
        // We will pass the image path and let the Detail screen handle prediction if needed, 
        // OR we can predict here. The plan said "Pick image -> Predict -> Nav to Detail".
        // Let's navigate to detail and let it handle initialization validation.
        // Actually, RN app predicts then navigates. Let's stick to that flow for consistency in logic if possible,
        // but passing complex objects in routes can be tricky. 
        // Better: Navigate to Detail Screen with imagePath, and let DetailScreen run the prediction on init.
        
        if (mounted) {
           Navigator.pushNamed(
            context, 
            '/analysis-detail',
            arguments: {'imageUri': image.path, 'source': 'gallery'}
          );
        }
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal mengambil gambar: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isPicking = false);
    }
  }

  Future<void> _handleTakePhoto() async {
    try {
      final ImagePicker picker = ImagePicker();
      final XFile? image = await picker.pickImage(source: ImageSource.camera);
      
      if (image != null && mounted) {
        Navigator.pushNamed(
          context,
          '/analysis-detail',
          arguments: {'imageUri': image.path, 'source': 'camera'}
        );
      }
    } catch (e) {
      debugPrint('Error taking photo: $e');
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Gagal mengambil foto: $e')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppColors.background,
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Header
              const SizedBox(height: 20),
              Text('Halo 👋', style: AppTextStyles.h3.copyWith(color: AppColors.textSecondary)),
              Text('Dentalogic8', style: AppTextStyles.h1),
              
              const SizedBox(height: 32),
              
              // Main Action
              ActionCard(
                title: 'Ambil Foto Baru',
                description: 'Gunakan kamera untuk mengambil foto gigi.',
                icon: Icons.camera_alt,
                iconColor: AppColors.primary,
                iconBgColor: const Color(0xFFE0F2FE),
                onTap: _handleTakePhoto,
              ),
              
              const SizedBox(height: 16),
              
              // Secondary Action
              SecondaryActionCard(
                title: 'Unggah dari Galeri',
                description: 'Pilih foto yang sudah ada di HP.',
                icon: Icons.photo_library, // Using Material Icons as simpler substitute
                onTap: _handleUploadImage,
                isLoading: _isPicking,
              ),

              const SizedBox(height: 32),
              
              // Tips Section
              Text('Tips Pengambilan Foto', style: AppTextStyles.h3),
              const SizedBox(height: 16),
              _buildTipItem(Icons.lightbulb, Colors.green, 'Gunakan pencahayaan yang cukup agar detail gigi terlihat jelas.'),
              _buildTipItem(Icons.center_focus_strong, Colors.blue, 'Posisikan kamera fokus pada area gigi yang ingin diperiksa.'),
              _buildTipItem(Icons.back_hand, Colors.orange, 'Pastikan kamera stabil dan tidak goyang saat pengambilan gambar.'),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildTipItem(IconData icon, Color color, String text) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withOpacity(0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(icon, size: 16, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(text, style: AppTextStyles.body.copyWith(height: 1.4)),
          ),
        ],
      ),
    );
  }
}

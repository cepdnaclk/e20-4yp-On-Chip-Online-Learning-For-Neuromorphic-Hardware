#ifndef NOMAD_ENV_MNIST_LOADER_H
#define NOMAD_ENV_MNIST_LOADER_H

#include <cstdint>
#include <fstream>
#include <iostream>
#include <string>
#include <vector>

namespace nomad {

/// @brief MNIST IDX file format loader.
///
/// Reads the standard MNIST dataset files (train-images-idx3-ubyte,
/// train-labels-idx1-ubyte, etc.) and provides access to the raw
/// pixel data and labels.
///
/// IDX file format:
///   - Magic number (4 bytes, big-endian): identifies file type
///   - Dimension sizes (4 bytes each, big-endian)
///   - Data bytes
///
/// Images are 28x28 grayscale pixels (0-255), stored row-major.
/// Labels are single bytes (0-9).
///
class MNISTLoader {
public:
  /// A single MNIST image: 784 pixels (28x28), values in [0, 255].
  struct Image {
    std::vector<uint8_t> pixels; ///< 784 pixel values.
    uint8_t label;               ///< Digit label (0-9).

    Image() : pixels(784, 0), label(0) {}
  };

  MNISTLoader() = default;

  /// @brief Load MNIST data from the given directory.
  ///
  /// Expects files named:
  ///   - train-images-idx3-ubyte (or with .gz stripped)
  ///   - train-labels-idx1-ubyte
  /// Or for test set:
  ///   - t10k-images-idx3-ubyte
  ///   - t10k-labels-idx1-ubyte
  ///
  /// @param data_dir   Directory containing MNIST files.
  /// @param train      If true, load training set; else test set.
  /// @param max_samples Maximum samples to load (0 = all).
  /// @return true if loaded successfully.
  ///
  bool load(const std::string &data_dir, bool train = true,
            int max_samples = 0) {
    std::string img_file, lbl_file;

    if (train) {
      img_file = data_dir + "/train-images-idx3-ubyte";
      lbl_file = data_dir + "/train-labels-idx1-ubyte";
    } else {
      img_file = data_dir + "/t10k-images-idx3-ubyte";
      lbl_file = data_dir + "/t10k-labels-idx1-ubyte";
    }

    // Try alternate names with .idx3-ubyte extension.
    if (!file_exists(img_file)) {
      img_file = data_dir + (train ? "/train-images.idx3-ubyte"
                                   : "/t10k-images.idx3-ubyte");
    }
    if (!file_exists(lbl_file)) {
      lbl_file = data_dir + (train ? "/train-labels.idx1-ubyte"
                                   : "/t10k-labels.idx1-ubyte");
    }

    if (!load_images(img_file)) {
      std::cerr << "MNISTLoader: failed to load images from " << img_file
                << "\n";
      return false;
    }
    if (!load_labels(lbl_file)) {
      std::cerr << "MNISTLoader: failed to load labels from " << lbl_file
                << "\n";
      return false;
    }

    if (images_.size() != labels_.size()) {
      std::cerr << "MNISTLoader: image/label count mismatch ("
                << images_.size() << " vs " << labels_.size() << ")\n";
      return false;
    }

    // Combine into Image structs.
    int count = static_cast<int>(images_.size());
    if (max_samples > 0 && max_samples < count) {
      count = max_samples;
    }

    data_.clear();
    data_.reserve(count);
    for (int i = 0; i < count; ++i) {
      Image img;
      img.pixels = images_[i];
      img.label = labels_[i];
      data_.push_back(std::move(img));
    }

    return true;
  }

  /// @brief Get loaded images.
  const std::vector<Image> &data() const { return data_; }

  /// @brief Number of loaded samples.
  int size() const { return static_cast<int>(data_.size()); }

  /// @brief Access individual sample.
  const Image &operator[](int idx) const { return data_[idx]; }

  /// @brief Image width (always 28 for MNIST).
  static constexpr int width() { return 28; }

  /// @brief Image height (always 28 for MNIST).
  static constexpr int height() { return 28; }

  /// @brief Total pixels per image (always 784).
  static constexpr int pixel_count() { return 784; }

private:
  std::vector<Image> data_;
  std::vector<std::vector<uint8_t>> images_;
  std::vector<uint8_t> labels_;

  /// Read a 32-bit big-endian integer from a stream.
  static uint32_t read_u32_be(std::ifstream &ifs) {
    uint8_t bytes[4];
    ifs.read(reinterpret_cast<char *>(bytes), 4);
    return (static_cast<uint32_t>(bytes[0]) << 24) |
           (static_cast<uint32_t>(bytes[1]) << 16) |
           (static_cast<uint32_t>(bytes[2]) << 8) |
           (static_cast<uint32_t>(bytes[3]));
  }

  static bool file_exists(const std::string &path) {
    std::ifstream f(path);
    return f.good();
  }

  /// Load images from IDX3 file.
  bool load_images(const std::string &path) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs.is_open())
      return false;

    uint32_t magic = read_u32_be(ifs);
    if (magic != 0x00000803) {
      std::cerr << "MNISTLoader: bad image magic: 0x" << std::hex << magic
                << std::dec << "\n";
      return false;
    }

    uint32_t num_images = read_u32_be(ifs);
    uint32_t rows = read_u32_be(ifs);
    uint32_t cols = read_u32_be(ifs);

    if (rows != 28 || cols != 28) {
      std::cerr << "MNISTLoader: unexpected image dimensions: " << rows << "x"
                << cols << "\n";
      return false;
    }

    images_.resize(num_images);
    for (uint32_t i = 0; i < num_images; ++i) {
      images_[i].resize(784);
      ifs.read(reinterpret_cast<char *>(images_[i].data()), 784);
    }

    return ifs.good();
  }

  /// Load labels from IDX1 file.
  bool load_labels(const std::string &path) {
    std::ifstream ifs(path, std::ios::binary);
    if (!ifs.is_open())
      return false;

    uint32_t magic = read_u32_be(ifs);
    if (magic != 0x00000801) {
      std::cerr << "MNISTLoader: bad label magic: 0x" << std::hex << magic
                << std::dec << "\n";
      return false;
    }

    uint32_t num_labels = read_u32_be(ifs);
    labels_.resize(num_labels);
    ifs.read(reinterpret_cast<char *>(labels_.data()), num_labels);

    return ifs.good();
  }
};

} // namespace nomad

#endif // NOMAD_ENV_MNIST_LOADER_H

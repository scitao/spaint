/**
 * spaint: VOPFeatureCalculator_CPU.cpp
 */

#include "features/cpu/VOPFeatureCalculator_CPU.h"

#include <cmath>
#include <vector>

#include <ITMLib/Engine/DeviceAgnostic/ITMRepresentationAccess.h>

#include "features/shared/VOPFeatureCalculator_Shared.h"

namespace spaint {

//#################### CONSTRUCTORS ####################

VOPFeatureCalculator_CPU::VOPFeatureCalculator_CPU(size_t maxVoxelLocationCount, size_t patchSize, float patchSpacing)
: VOPFeatureCalculator(maxVoxelLocationCount, patchSize, patchSpacing)
{}

//#################### PRIVATE MEMBER FUNCTIONS ####################

void VOPFeatureCalculator_CPU::calculate_surface_normals(const ORUtils::MemoryBlock<Vector3s>& voxelLocationsMB,
                                                         const SpaintVoxel *voxelData, const ITMVoxelIndex::IndexData *indexData) const
{
  Vector3f *surfaceNormals = m_surfaceNormalsMB.GetData(MEMORYDEVICE_CPU);
  const Vector3s *voxelLocations = voxelLocationsMB.GetData(MEMORYDEVICE_CPU);
  const int voxelLocationCount = static_cast<int>(voxelLocationsMB.dataSize);

#ifdef WITH_OPENMP
  #pragma omp parallel for
#endif
  for(int voxelLocationIndex = 0; voxelLocationIndex < voxelLocationCount; ++voxelLocationIndex)
  {
    write_surface_normal(voxelLocationIndex, voxelLocations, voxelData, indexData, surfaceNormals);
  }
}

void VOPFeatureCalculator_CPU::convert_patches_to_lab(int voxelLocationCount, ORUtils::MemoryBlock<float>& featuresMB) const
{
  const size_t featureCount = get_feature_count();
  float *features = featuresMB.GetData(MEMORYDEVICE_CPU);

#ifdef WITH_OPENMP
  #pragma omp parallel for
#endif
  for(int voxelLocationIndex = 0; voxelLocationIndex < voxelLocationCount; ++voxelLocationIndex)
  {
    convert_patch_to_lab(voxelLocationIndex, featureCount, features);
  }
}

void VOPFeatureCalculator_CPU::generate_coordinate_systems(int voxelLocationCount) const
{
  const Vector3f *surfaceNormals = m_surfaceNormalsMB.GetData(MEMORYDEVICE_CPU);
  Vector3f *xAxes = m_xAxesMB.GetData(MEMORYDEVICE_CPU);
  Vector3f *yAxes = m_yAxesMB.GetData(MEMORYDEVICE_CPU);

#ifdef WITH_OPENMP
  #pragma omp parallel for
#endif
  for(int voxelLocationIndex = 0; voxelLocationIndex < voxelLocationCount; ++voxelLocationIndex)
  {
    generate_coordinate_system(voxelLocationIndex, surfaceNormals, xAxes, yAxes);
  }
}

void VOPFeatureCalculator_CPU::generate_rgb_patches(const ORUtils::MemoryBlock<Vector3s>& voxelLocationsMB,
                                                    const SpaintVoxel *voxelData, const ITMVoxelIndex::IndexData *indexData,
                                                    ORUtils::MemoryBlock<float>& featuresMB) const
{
  const size_t featureCount = get_feature_count();
  float *features = featuresMB.GetData(MEMORYDEVICE_CPU);
  const Vector3f *xAxes = m_xAxesMB.GetData(MEMORYDEVICE_CPU);
  const Vector3f *yAxes = m_yAxesMB.GetData(MEMORYDEVICE_CPU);
  const Vector3s *voxelLocations = voxelLocationsMB.GetData(MEMORYDEVICE_CPU);
  const int voxelLocationCount = static_cast<int>(voxelLocationsMB.dataSize);

#ifdef WITH_OPENMP
  #pragma omp parallel for
#endif
  for(int voxelLocationIndex = 0; voxelLocationIndex < voxelLocationCount; ++voxelLocationIndex)
  {
    generate_rgb_patch(voxelLocationIndex, voxelLocations, xAxes, yAxes, voxelData, indexData, m_patchSize, m_patchSpacing, featureCount, features);
  }
}

void VOPFeatureCalculator_CPU::update_coordinate_systems(int voxelLocationCount, const ORUtils::MemoryBlock<float>& featuresMB) const
{
  const size_t binCount = 36; // 10 degrees per bin
  const float *features = featuresMB.GetData(MEMORYDEVICE_CPU);
  const size_t featureCount = get_feature_count();
  const size_t patchArea = m_patchSize * m_patchSize;
  Vector3f *xAxes = m_xAxesMB.GetData(MEMORYDEVICE_CPU);
  Vector3f *yAxes = m_yAxesMB.GetData(MEMORYDEVICE_CPU);

#if 1
  std::vector<std::vector<double> > histograms(voxelLocationCount, std::vector<double>(binCount));
  std::vector<std::vector<float> > intensities(voxelLocationCount, std::vector<float>(patchArea));

  int threadCount = voxelLocationCount * patchArea; 

#ifdef WITH_OPENMP
  #pragma omp parallel for
#endif
  for(int tid = 0; tid < threadCount; ++tid)
  {
    int voxelLocationIndex = tid / patchArea;
    compute_intensities_for_patch(tid, patchArea, features, featureCount, m_patchSize, &intensities[voxelLocationIndex][0]);
  }

#ifdef WITH_OPENMP
  #pragma omp parallel for
#endif
  for(int tid = 0; tid < threadCount; ++tid)
  {
    int voxelLocationIndex = tid / patchArea;
    compute_histogram_for_patch(tid, patchArea, m_patchSize, &intensities[voxelLocationIndex][0], binCount, &histograms[voxelLocationIndex][0]);
  }

#ifdef WITH_OPENMP
  //#pragma omp parallel for
#endif
  for(int tid = 0, threadCount = voxelLocationCount * patchArea; tid < threadCount; ++tid)
  {
    if(tid % patchArea == 0)
    {
      int voxelLocationIndex = tid / patchArea;

      size_t dominantBin;
      double highestBinValue = 0;
      for(size_t binIndex = 0; binIndex < binCount; ++binIndex)
      {
        double binValue = histograms[voxelLocationIndex][binIndex];
        if(binValue >= highestBinValue)
        {
          highestBinValue = binValue;
          dominantBin = binIndex;
        }
      }

      float binAngle = static_cast<float>(2 * M_PI) / binCount;
      float dominantOrientation = dominantBin * binAngle;

      float c = cos(dominantOrientation);
      float s = sin(dominantOrientation);

      Vector3f xAxis = xAxes[voxelLocationIndex];
      Vector3f yAxis = yAxes[voxelLocationIndex];

      xAxes[voxelLocationIndex] = c * xAxis + s * yAxis;
      yAxes[voxelLocationIndex] = c * yAxis - s * xAxis;
    }
  }
#endif
}

}

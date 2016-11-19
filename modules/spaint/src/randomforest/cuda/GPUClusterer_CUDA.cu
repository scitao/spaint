/**
 * spaint: GPUClusterer_CUDA.cu
 * Copyright (c) Torr Vision Group, University of Oxford, 2016. All rights reserved.
 */

#include "randomforest/cuda/GPUClusterer_CUDA.h"

#include "util/MemoryBlockFactory.h"

#include <iostream>

namespace spaint
{
__global__ void ck_reset_temporaries(int *clustersPerReservoir,
    int *clusterSizes, int *clusterSizesHistogram, int reservoirCapacity,
    int startReservoirIdx)
{
  const int reservoirIdx = threadIdx.x + startReservoirIdx;
  const int reservoirOffset = reservoirIdx * reservoirCapacity;

  // Reset number of clusters per reservoir
  clustersPerReservoir[reservoirIdx] = 0;

  // Reset cluster sizes and histogram
  for (int i = 0; i < reservoirCapacity; ++i)
  {
    clusterSizes[reservoirOffset + i] = 0;
    clusterSizesHistogram[reservoirOffset + i] = 0;
  }
}

__global__ void ck_compute_density(const PositionColourExample *examples,
    const int *reservoirSizes, float *densities, int reservoirCapacity,
    int startReservoirIdx, float sigma)
{
  // The assumption is that the kernel indices are always valid.
  const int reservoirIdx = blockIdx.x + startReservoirIdx;
  const int reservoirOffset = reservoirIdx * reservoirCapacity;
  const int reservoirSize = reservoirSizes[reservoirIdx];
  const int elementIdx = threadIdx.x;
  const int elementOffset = reservoirOffset + elementIdx;

  const float three_sigma_sq = (3.f * sigma) * (3.f * sigma); // Points farther away have small contribution to the density
  const float minus_one_over_two_sigma_sq = -1.f / (2.f * sigma * sigma);

  float density = 0.f;

  if (elementIdx < reservoirSize)
  {
    const Vector3f centerPosition = examples[elementOffset].position;

    for (int i = 0; i < reservoirSize; ++i)
    {
      const Vector3f examplePosition = examples[reservoirOffset + i].position;
      const Vector3f diff = examplePosition - centerPosition;
      const float normSq = dot(diff, diff);

      if (normSq < three_sigma_sq)
      {
        density += expf(normSq * minus_one_over_two_sigma_sq);
      }
    }
  }

  densities[elementOffset] = density;
}

__global__ void ck_link_neighbors(const PositionColourExample *examples,
    const int *reservoirSizes, const float *densities, int *parents,
    int *clusterIndices, int *nbClustersPerReservoir, int reservoirCapacity,
    int startReservoirIdx, float tauSq)
{
  // The assumption is that the kernel indices are always valid.
  const int reservoirIdx = blockIdx.x + startReservoirIdx;
  const int reservoirOffset = reservoirIdx * reservoirCapacity;
  const int reservoirSize = reservoirSizes[reservoirIdx];
  const int elementIdx = threadIdx.x;
  const int elementOffset = reservoirOffset + elementIdx;

  int parentIdx = elementIdx;
  int clusterIdx = -1;

  if (elementIdx < reservoirSize)
  {
    const Vector3f centerPosition = examples[elementOffset].position;
    const float centerDensity = densities[elementOffset];
    float minDistance = tauSq;

    for (int i = 0; i < reservoirSize; ++i)
    {
      if (i == elementIdx)
        continue;

      const Vector3f examplePosition = examples[reservoirOffset + i].position;
      const float exampleDensity = densities[reservoirOffset + i];

      const Vector3f diff = examplePosition - centerPosition;
      const float normSq = dot(diff, diff);

      if (normSq < minDistance && centerDensity < exampleDensity)
      {
        minDistance = normSq;
        parentIdx = i;
      }
    }

    // current element is the root of a subtree, get a unique cluster index
    if (parentIdx == elementIdx)
    {
      clusterIdx = atomicAdd(&nbClustersPerReservoir[reservoirIdx], 1);
    }
  }

  parents[elementOffset] = parentIdx;
  clusterIndices[elementOffset] = clusterIdx;
}

__global__ void ck_identify_clusters(const int *reservoirSizes,
    const int *parents, int *clusterIndices, int *clusterSizes,
    int reservoirCapacity, int startReservoirIdx)
{
  // The assumption is that the kernel indices are always valid.
  const int reservoirIdx = blockIdx.x + startReservoirIdx;
  const int reservoirOffset = reservoirIdx * reservoirCapacity;
  const int reservoirSize = reservoirSizes[reservoirIdx];
  const int elementIdx = threadIdx.x;
  const int elementOffset = reservoirOffset + elementIdx;

  // No need to check if the current element is valid
  // ck_link_neighbors sets the parent for invalid elements to themselves
  int parentIdx = parents[elementOffset];
  int currentIdx = elementIdx;
  while (parentIdx != currentIdx)
  {
    currentIdx = parentIdx;
    parentIdx = parents[reservoirOffset + parentIdx];
  }

  // found the root of the subtree, get its cluster idx
  const int clusterIdx = clusterIndices[reservoirOffset + parentIdx];
  clusterIndices[elementOffset] = clusterIdx;

  // If it's a valid cluster then increase its size
  if (clusterIdx >= 0)
  {
    atomicAdd(&clusterSizes[reservoirOffset + clusterIdx], 1);
  }
}

__global__ void ck_compute_cluster_histogram(const int *clusterSizes,
    const int *nbClustersPerReservoir, int *clusterSizesHistogram,
    int reservoirCapacity, int startReservoirIdx)
{
  // The assumption is that the kernel indices are always valid.
  const int reservoirIdx = blockIdx.x + startReservoirIdx;
  const int reservoirOffset = reservoirIdx * reservoirCapacity;
  const int validClusters = nbClustersPerReservoir[reservoirIdx];
  const int clusterIdx = threadIdx.x;

  if (clusterIdx >= validClusters)
    return;

  const int clusterSize = clusterSizes[reservoirOffset + clusterIdx];
  atomicAdd(&clusterSizesHistogram[reservoirOffset + clusterSize], 1);
}

__global__ void ck_select_clusters(const int *clusterSizes,
    const int *clusterSizesHistogram, const int *nbClustersPerReservoir,
    int *selectedClusters, int reservoirCapacity, int startReservoirIdx,
    int maxSelectedClusters, int minClusterSize)
{
  // The assumption is that the kernel indices are always valid.
  // "Sequential kernel": only one block is launched
  const int reservoirIdx = threadIdx.x + startReservoirIdx;
  const int reservoirOffset = reservoirIdx * reservoirCapacity;
  const int validClusters = nbClustersPerReservoir[reservoirIdx];
  const int selectedClustersOffset = reservoirIdx * maxSelectedClusters;

  // Reset output
  for (int i = 0; i < maxSelectedClusters; ++i)
  {
    selectedClusters[selectedClustersOffset + i] = -1;
  }

  // Scan the histogram from the top to find the minimum cluster size we want to select
  int nbSelectedClusters = 0;
  int selectedClusterSize = reservoirCapacity - 1;
  for (;
      selectedClusterSize >= minClusterSize
          && nbSelectedClusters < maxSelectedClusters; --selectedClusterSize)
  {
    nbSelectedClusters += clusterSizesHistogram[reservoirOffset
        + selectedClusterSize];
  }

  // Empty reservoir
  if (nbSelectedClusters == 0)
    return;

  // nbSelectedClusters might be greater than maxSelectedClusters if more clusters had the same size,
  // need to keep this into account: at first add all clusters with size greater than minClusterSize
  // then another loop over the clusters add as many clusters with size == selectedClusterSize as possible

  nbSelectedClusters = 0;

  // first loop, >
  for (int i = 0; i < validClusters && nbSelectedClusters < maxSelectedClusters;
      ++i)
  {
    if (clusterSizes[reservoirOffset + i] > selectedClusterSize)
    {
      selectedClusters[selectedClustersOffset + nbSelectedClusters++] = i;
    }
  }

  // second loop, ==
  for (int i = 0; i < validClusters && nbSelectedClusters < maxSelectedClusters;
      ++i)
  {
    if (clusterSizes[reservoirOffset + i] == selectedClusterSize)
    {
      selectedClusters[selectedClustersOffset + nbSelectedClusters++] = i;
    }
  }

  // Sort clusters by descending number of inliers
  // Quadratic but small enough to not care for now
  for (int i = 0; i < nbSelectedClusters; ++i)
  {
    int maxSize = clusterSizes[reservoirOffset
        + selectedClusters[selectedClustersOffset + i]];
    int maxIdx = i;

    for (int j = i + 1; j < nbSelectedClusters; ++j)
    {
      int size = clusterSizes[reservoirOffset
          + selectedClusters[selectedClustersOffset + j]];
      if (size > maxSize)
      {
        maxSize = size;
        maxIdx = j;
      }
    }

    // Swap
    if (maxIdx != i)
    {
      int temp = selectedClusters[selectedClustersOffset + i];
      selectedClusters[selectedClustersOffset + i] =
          selectedClusters[selectedClustersOffset + maxIdx];
      selectedClusters[selectedClustersOffset + maxIdx] = temp;
    }
  }
}

__global__ void ck_compute_modes(const PositionColourExample *examples,
    const int *reservoirSizes, const int *clusterIndices,
    const int *selectedClusters, ScorePrediction *predictions,
    int reservoirCapacity, int startReservoirIdx, int maxSelectedClusters)
{
  // One thread per cluster, one block per reservoir
  const int reservoirIdx = blockIdx.x + startReservoirIdx;
  const int reservoirOffset = reservoirIdx * reservoirCapacity;
  const int reservoirSize = reservoirSizes[reservoirIdx];

  const int clusterIdx = threadIdx.x;
  const int selectedClustersOffset = reservoirIdx * maxSelectedClusters;

  ScorePrediction &reservoirPrediction = predictions[reservoirIdx];
  if (threadIdx.x == 0)
    reservoirPrediction.nbModes = 0;

  __syncthreads();

  const int selectedClusterId = selectedClusters[selectedClustersOffset
      + clusterIdx];
  if (selectedClusterId >= 0)
  {
    // compute position and colour mean
    int sampleCount = 0;
    Vector3f positionMean(0.f);
    Vector3f colourMean(0.f);

    // Iterate over all examples and use only those belonging to selectedClusterId
    for (int sampleIdx = 0; sampleIdx < reservoirSize; ++sampleIdx)
    {
      const int sampleCluster = clusterIndices[reservoirOffset + sampleIdx];
      if (sampleCluster == selectedClusterId)
      {
        const PositionColourExample &sample = examples[reservoirOffset
            + sampleIdx];

        ++sampleCount;
        positionMean += sample.position;
        colourMean += sample.colour.toFloat();
      }
    }

    //this mode is invalid..
    if (sampleCount <= 1) // Should never reach this point since we check minClusterSize earlier
      return;

    positionMean /= static_cast<float>(sampleCount);
    colourMean /= static_cast<float>(sampleCount);

    // Now iterate again and compute the covariance
    Matrix3f positionCovariance;
    positionCovariance.setZeros();

    for (int sampleIdx = 0; sampleIdx < reservoirSize; ++sampleIdx)
    {
      const int sampleCluster = clusterIndices[reservoirOffset + sampleIdx];
      if (sampleCluster == selectedClusterId)
      {
        const PositionColourExample &sample = examples[reservoirOffset
            + sampleIdx];

        for (int i = 0; i < 3; ++i)
        {
          for (int j = 0; j < 3; ++j)
          {
            positionCovariance.m[i * 3 + j] += (sample.position.v[i]
                - positionMean.v[i])
                * (sample.position.v[j] - positionMean.v[j]);
          }
        }
      }
    }

    positionCovariance /= static_cast<float>(sampleCount - 1);
    const float positionDeterminant = positionCovariance.det();

    // Get the mode idx
    const int modeIdx = atomicAdd(&reservoirPrediction.nbModes, 1);

    // Fill the mode
    ScoreMode &outMode = reservoirPrediction.modes[modeIdx];
    outMode.nbInliers = sampleCount;
    outMode.position = positionMean;
    outMode.determinant = positionDeterminant;
    positionCovariance.inv(outMode.positionInvCovariance);
    outMode.colour = colourMean.toUChar();
  }
}

GPUClusterer_CUDA::GPUClusterer_CUDA(float sigma, float tau, int minClusterSize) :
    GPUClusterer(sigma, tau, minClusterSize)
{
  MemoryBlockFactory &mbf = MemoryBlockFactory::instance();
  m_densities = mbf.make_image<float>();
  m_parents = mbf.make_image<int>();
  m_clusterIdx = mbf.make_image<int>();
  m_clusterSizes = mbf.make_image<int>();
  m_clusterSizesHistogram = mbf.make_image<int>();
  m_selectedClusters = mbf.make_image<int>();
  m_nbClustersPerReservoir = mbf.make_image<int>();
}

void GPUClusterer_CUDA::find_modes(const PositionReservoir_CPtr &reservoirs,
    ScorePredictionsBlock_Ptr &predictions, size_t startIdx, size_t count)
{
  const int nbReservoirs = reservoirs->get_reservoirs_count();
  const int reservoirCapacity = reservoirs->get_capacity();

  if (startIdx + count > nbReservoirs)
    throw std::runtime_error("startIdx + count > nbReservoirs");

  {
    // Happens only once
    const Vector2i temporariesSize(reservoirCapacity, nbReservoirs);
    m_densities->ChangeDims(temporariesSize);
    m_parents->ChangeDims(temporariesSize);
    m_clusterIdx->ChangeDims(temporariesSize);
    m_clusterSizes->ChangeDims(temporariesSize);
    m_clusterSizesHistogram->ChangeDims(temporariesSize);

    m_selectedClusters->ChangeDims(
        Vector2i(ScorePrediction::MAX_MODES, nbReservoirs));

    m_nbClustersPerReservoir->ChangeDims(Vector2i(1, nbReservoirs));
  }

  const PositionColourExample *examples = reservoirs->get_reservoirs()->GetData(
      MEMORYDEVICE_CUDA);
  const int *reservoirSizes = reservoirs->get_reservoirs_size()->GetData(
      MEMORYDEVICE_CUDA);
  float *densities = m_densities->GetData(MEMORYDEVICE_CUDA);

  dim3 blockSize(reservoirCapacity); // One thread per item in each reservoir
  dim3 gridSize(count); // One block per reservoir to process

  int *nbClustersPerReservoir = m_nbClustersPerReservoir->GetData(
      MEMORYDEVICE_CUDA);
  int *clusterSizes = m_clusterSizes->GetData(MEMORYDEVICE_CUDA);
  int *clusterSizesHistogram = m_clusterSizesHistogram->GetData(
      MEMORYDEVICE_CUDA);

  // 1 single block, 1 thread per reservoir
  ck_reset_temporaries<<<1, gridSize>>>(nbClustersPerReservoir, clusterSizes,
      clusterSizesHistogram, reservoirCapacity, startIdx);
  ORcudaKernelCheck;

  ck_compute_density<<<gridSize, blockSize>>>(examples, reservoirSizes, densities, reservoirCapacity,
      startIdx, m_sigma);
  ORcudaKernelCheck;

  int *parents = m_parents->GetData(MEMORYDEVICE_CUDA);
  int *clusterIndices = m_clusterIdx->GetData(MEMORYDEVICE_CUDA);

  ck_link_neighbors<<<gridSize, blockSize>>>(examples, reservoirSizes, densities, parents, clusterIndices,
      nbClustersPerReservoir, reservoirCapacity, startIdx, m_tau * m_tau);
  ORcudaKernelCheck;

  ck_identify_clusters<<<gridSize, blockSize>>>(reservoirSizes, parents, clusterIndices, clusterSizes,
      reservoirCapacity, startIdx);
  ORcudaKernelCheck;

  ck_compute_cluster_histogram<<<gridSize, blockSize>>>(clusterSizes, nbClustersPerReservoir,
      clusterSizesHistogram, reservoirCapacity, startIdx);
  ORcudaKernelCheck;

  int *selectedClusters = m_selectedClusters->GetData(MEMORYDEVICE_CUDA);
  // 1 single block, 1 thread per reservoir
  ck_select_clusters<<<1, gridSize>>>(clusterSizes, clusterSizesHistogram,
      nbClustersPerReservoir, selectedClusters, reservoirCapacity, startIdx,
      ScorePrediction::MAX_MODES, m_minClusterSize);
  ORcudaKernelCheck;

  ScorePrediction *predictionsData = predictions->GetData(MEMORYDEVICE_CUDA);
  ck_compute_modes<<<gridSize, ScorePrediction::MAX_MODES>>>(examples, reservoirSizes, clusterIndices, selectedClusters,
      predictionsData, reservoirCapacity, startIdx,
      ScorePrediction::MAX_MODES);
  ORcudaKernelCheck;

//  m_nbClustersPerReservoir->UpdateHostFromDevice();
//  m_clusterSizes->UpdateHostFromDevice();
//  reservoirs->get_reservoirs_size()->UpdateHostFromDevice();
//
//  for (int i = 0; i < count; ++i)
//  {
//    std::cout << "Reservoir " << i + startIdx << " has "
//        << m_nbClustersPerReservoir->GetData(MEMORYDEVICE_CPU)[i + startIdx]
//        << " clusters and "
//        << reservoirs->get_reservoirs_size()->GetData(MEMORYDEVICE_CPU)[i
//            + startIdx] << " elements." << std::endl;
//    for (int j = 0;
//        j < m_nbClustersPerReservoir->GetData(MEMORYDEVICE_CPU)[i + startIdx];
//        ++j)
//    {
//      std::cout << "\tCluster " << j << ": "
//          << m_clusterSizes->GetData(MEMORYDEVICE_CPU)[(i + startIdx)
//              * reservoirCapacity + j] << " elements." << std::endl;
//    }
//  }
}

}
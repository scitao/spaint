/**
 * spaint: VisualiserFactory.cpp
 * Copyright (c) Torr Vision Group, University of Oxford, 2016. All rights reserved.
 */

#include "visualisation/VisualiserFactory.h"
using namespace ITMLib;

#include "visualisation/cpu/DepthVisualiser_CPU.h"
#include "visualisation/cpu/SemanticVisualiser_CPU.h"

#ifdef WITH_CUDA
#include "visualisation/cuda/DepthVisualiser_CUDA.h"
#include "visualisation/cuda/SemanticVisualiser_CUDA.h"
#endif

namespace spaint {

//#################### PUBLIC STATIC MEMBER FUNCTIONS ####################

DepthVisualiser_CPtr VisualiserFactory::make_depth_visualiser(ITMLibSettings::DeviceType deviceType)
{
  DepthVisualiser_CPtr visualiser;

  if(deviceType == ITMLibSettings::DEVICE_CUDA)
  {
#ifdef WITH_CUDA
    visualiser.reset(new DepthVisualiser_CUDA);
#else
    // This should never happen as things stand - we set deviceType to DEVICE_CPU if CUDA support isn't available.
    throw std::runtime_error("Error: CUDA support not currently available. Reconfigure in CMake with the WITH_CUDA option set to on.");
#endif
  }
  else
  {
    visualiser.reset(new DepthVisualiser_CPU);
  }

  return visualiser;
}

SemanticVisualiser_CPtr VisualiserFactory::make_semantic_visualiser(size_t maxLabelCount, ITMLibSettings::DeviceType deviceType)
{
  SemanticVisualiser_CPtr visualiser;

  if(deviceType == ITMLibSettings::DEVICE_CUDA)
  {
#ifdef WITH_CUDA
    visualiser.reset(new SemanticVisualiser_CUDA(maxLabelCount));
#else
    // This should never happen as things stand - we set deviceType to DEVICE_CPU if CUDA support isn't available.
    throw std::runtime_error("Error: CUDA support not currently available. Reconfigure in CMake with the WITH_CUDA option set to on.");
#endif
  }
  else
  {
    visualiser.reset(new SemanticVisualiser_CPU(maxLabelCount));
  }

  return visualiser;
}

}

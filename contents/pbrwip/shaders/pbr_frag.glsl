varying vec3 vViewPosition;
varying vec3 vNormal;
varying vec3 vTangent;
varying vec3 vBinormal;

//-------------------------------------------------------------------------
// uniforms
uniform float metallic;
uniform float roughness;
uniform vec3 albedo;
uniform vec3 dirLightDir;
uniform vec3 dirLightColor;
uniform sampler2D dfgMap;
uniform float energyCompensation;
uniform float anisotropy;

//-------------------------------------------------------------------------
// defines
#define PI 3.14159265359
#define PI2 6.28318530718
#define RECIPROCAL_PI 0.31830988618
#define RECIPROCAL_PI2 0.15915494
#define LOG2 1.442695
#define EPSILON 1e-6

#define MIN_ROUGHNESS              0.045
#define MIN_LINEAR_ROUGHNESS       0.002025
#define MAX_CLEAR_COAT_ROUGHNESS   0.6

float pow2(const in float x) { return x*x; }
vec3 transformDirection(in vec3 dir, in mat4 matrix) {
  return normalize((matrix * vec4(dir, 0.0)).xyz);
}
vec3 inverseTransformDirection(in vec3 dir, in mat4 matrix) {
  return normalize((vec4(dir, 0.0) * matrix).xyz);
}

float luminance(const vec3 linear) {
    return dot(linear, vec3(0.2126, 0.7152, 0.0722));
}

vec3 heatmap(float v) {
    vec3 r = v * 2.1 - vec3(1.8, 1.14, 0.3);
    return 1.0 - r * r;
}

//------------------------------------------------------------------------------
// Tone-mapping operators for LDR output
//------------------------------------------------------------------------------

vec3 Tonemap_Linear(const vec3 x) {
    return x;
}

vec3 Tonemap_Reinhard(const vec3 x) {
    // Reinhard et al. 2002, "Photographic Tone Reproduction for Digital Images", Eq. 3
    return x / (1.0 + luminance(x));
}

vec3 Tonemap_Unreal(const vec3 x) {
    // Unreal, Documentation: "Color Grading"
    // Adapted to be close to Tonemap_ACES, with similar range
    // Gamma 2.2 correction is baked in, don't use with sRGB conversion!
    return x / (x + 0.155) * 1.019;
}

vec3 Tonemap_ACES(const vec3 x) {
    // Narkowicz 2015, "ACES Filmic Tone Mapping Curve"
    const float a = 2.51;
    const float b = 0.03;
    const float c = 2.43;
    const float d = 0.59;
    const float e = 0.14;
    return (x * (a * x + b)) / (x * (c * x + d) + e);
}


//------------------------------------------------------------------------------
// Debug tone-mapping operators, for LDR output
//------------------------------------------------------------------------------

/**
 * Converts the input HDR RGB color into one of 16 debug colors that represent
 * the pixel's exposure. When the output is cyan, the input color represents
 * middle gray (18% exposure). Every exposure stop above or below middle gray
 * causes a color shift.
 *
 * The relationship between exposures and colors is:
 *
 * -5EV  - black
 * -4EV  - darkest blue
 * -3EV  - darker blue
 * -2EV  - dark blue
 * -1EV  - blue
 *  OEV  - cyan
 * +1EV  - dark green
 * +2EV  - green
 * +3EV  - yellow
 * +4EV  - yellow-orange
 * +5EV  - orange
 * +6EV  - bright red
 * +7EV  - red
 * +8EV  - magenta
 * +9EV  - purple
 * +10EV - white
 */
// vec3 Tonemap_DisplayRange(const vec3 x) {
//     // 16 debug colors + 1 duplicated at the end for easy indexing
//     const vec3 debugColors[17] = vec3[](
//          vec3(0.0, 0.0, 0.0),         // black
//          vec3(0.0, 0.0, 0.1647),      // darkest blue
//          vec3(0.0, 0.0, 0.3647),      // darker blue
//          vec3(0.0, 0.0, 0.6647),      // dark blue
//          vec3(0.0, 0.0, 0.9647),      // blue
//          vec3(0.0, 0.9255, 0.9255),   // cyan
//          vec3(0.0, 0.5647, 0.0),      // dark green
//          vec3(0.0, 0.7843, 0.0),      // green
//          vec3(1.0, 1.0, 0.0),         // yellow
//          vec3(0.90588, 0.75294, 0.0), // yellow-orange
//          vec3(1.0, 0.5647, 0.0),      // orange
//          vec3(1.0, 0.0, 0.0),         // bright red
//          vec3(0.8392, 0.0, 0.0),      // red
//          vec3(1.0, 0.0, 1.0),         // magenta
//          vec3(0.6, 0.3333, 0.7882),   // purple
//          vec3(1.0, 1.0, 1.0),         // white
//          vec3(1.0, 1.0, 1.0)          // white
//     );

//     // The 5th color in the array (cyan) represents middle gray (18%)
//     // Every stop above or below middle gray causes a color shift
//     float v = log2(luminance(x) / 0.18);
//     v = clamp(v + 5.0, 0.0, 15.0);
//     int index = int(v);
//     return mix(debugColors[index], debugColors[index + 1], v - float(index));
// }

//-------------------------------------------------------------------------

struct IncidentLight {
  vec3 color;
  vec3 direction;
  bool visible;
};

struct ReflectedLight {
  vec3 directDiffuse;
  vec3 directSpecular;
  vec3 indirectDiffuse;
  vec3 indirectSpecular;
};

struct GeometricContext {
  vec3 position;
  vec3 normal;
  vec3 viewDir;
};

struct Material {
  vec3 diffuseColor;
  float specularRoughness;
  vec3 specularColor;

  float linearRoughness;
  float clearCoatRoughness;
  float linearClearCoatRoughness;
  float dotNV;
  vec2 dfg;
  vec3 energyCompensation;
  vec3 anisotropicT;
  vec3 anisotropicB;
  float anisotropy;
  mat3 tangentToWorld;
};

//-------------------------------------------------------------------------
// BRDFs

// ClearCoat
uniform float clearCoat;
uniform float clearCoatRoughness;

// Kelemen 2001, "A Microfacet Based Coupled Specular-Matte BRDF Model with Importance Sampling"
float V_Keleman(float dotLH) {
  return saturate(0.25 / (dotLH*dotLH));
}

float F_SchlickF(float f0, float f90, float dotVH) {
  return f0 + (f90-f0) * pow(1.0 - dotVH, 5.0);
}

// float F_SchlickF(float f0, float dotVH) {
//   return f0 + (1.0-f0) * pow(1.0 - saturate(dotVH), 5.0));
// }

vec2 PrefilteredDFG(float alpha, float dotNV) {
  return texture2D(dfgMap, vec2(dotNV, alpha)).rg;
}

vec2 PrefilteredDFG_approx(float alpha, float dotNV) {
  const vec4 c0 = vec4(-1.0, -0.0275, -0.572,  0.022);
  const vec4 c1 = vec4( 1.0,  0.0425,  1.040, -0.040);
  vec4 r = alpha * c0 + c1;
  float a004 = min(r.x * r.x, exp2(-9.28*dotNV))*r.x+r.y;
  return vec2(-1.04,1.04)*a004 + r.zw;
  // return vec2(1.0, pow(1.0-max(alpha,dotNV),3.0));
}

//------------------------------------------------------------------------------
// Index of refraction (IOR)
//------------------------------------------------------------------------------

float iorToF0(float transmittedIor, float incidentIor) {
    return pow2((transmittedIor - incidentIor) / (transmittedIor + incidentIor));
}

float f0ToIor(float f0) {
    float r = sqrt(f0);
    return (1.0 + r) / (1.0 - r);
}

vec3 f0ClearCoatToSurface(const vec3 f0) {
    // Approximation of iorTof0(f0ToIor(f0), 1.5)
    // This assumes that the clear coat layer has an IOR of 1.5
    return saturate(f0 * (f0 * (0.941892 - 0.263008 * f0) + 0.346479) - 0.0285998);
}

// Normalized Lambert
vec3 DiffuseBRDF(vec3 diffuseColor) {
  return diffuseColor / PI;
}

vec3 F_Schlick(vec3 specularColor, float dotVH) {
  return (specularColor + (1.0 - specularColor) * pow(1.0-dotVH, 5.0));
}

float D_GGX(float a, float dotNH) {
  float a2 = a*a;
  float dotNH2 = dotNH*dotNH;
  float d = dotNH2 * (a2 - 1.0) + 1.0;
  return a2 / (PI * d * d);
}

// Heitz 2014, "Understanding the Masking-Shadowing Function in Microfacet-Based BRDFs"
// Moving Frostbite to Physically Based Rendering 3.0
float V_SmithGGXCorrelated(float a, float dotNV, float dotNL) {
  float a2 = a*a;
  // dotNL and dotNV are explicitly swapped. This is not a mistake
  float gv = dotNL * sqrt((dotNV - a2 * dotNV)*dotNV + a2);
  float gl = dotNV * sqrt((dotNL - a2 * dotNL)*dotNL + a2);
  // float gv = dotNL * sqrt((1.0-a2)*dotNV*dotNV + a2);
  // float gl = dotNV * sqrt((1.0-a2)*dotNL*dotNL + a2);
  return 0.5 / max(gl+gv, EPSILON);
}

// Hammon 2017, "PBR Diffuse Lighting for GGX+Smith Microsurfaces"
float V_SmithGGXCorrelated_Fast(float a, float dotNV, float dotNL) {
  float v = 0.5 / mix(2.0*dotNL*dotNV, dotNL+dotNV, a);
  return saturate(v);
}

// Burley 2012, "Physically-Based Shading at Disney"
float D_GGX_Anisotropic(float at, float ab, float dotTH, float dotBH, float dotNH) {
  // The values at end ab are roughness^2. a2 is therefore roughness^4
  // The dot product below computes roughness^8. We cannot fit in fp16 without clamping
  // the roughness to too high values so we perform the dot product and the divison fp32
  float a2 = at*ab;
  vec3 d = vec3(ab*dotTH, at*dotBH, a2*dotNH);
  float d2 = dot(d,d);
  float b2 = a2/d2;
  return a2*b2*b2*(1.0/PI);
}

// Heitz 2014, "Understanding the Masking-Shadowing Function in Microfacet-Based BRDFs"
float V_SmithGGXCorrelated_Anisotropic(float at, float ab,
  float dotTV, float dotBV, float dotTL, float dotBL, float dotNV, float dotNL) {
  // TODO: lambdaV can be pre-computed for all the lights, it should be moved out of this function
  float lambdaV = dotNL * length(vec3(at*dotTV,ab*dotBV, dotNV));
  float lambdaL = dotNV * length(vec3(at*dotTL,ab*dotBL, dotNL));
  float v = 0.5 / (lambdaV + lambdaL);
  return saturate(v);
}

vec3 SpecularBRDF_Anisotropic(const in IncidentLight directLight, 
  const in GeometricContext geometry, const in Material material,
  float dotNL, float dotNH, float dotVH) {
  
  vec3 l = directLight.direction;
  vec3 t = material.anisotropicT;
  vec3 b = material.anisotropicB;
  vec3 v = geometry.viewDir;
  vec3 h = normalize(l+v);

  float dotTV = dot(t,v);
  float dotBV = dot(b,v);
  float dotTL = dot(t,l);
  float dotBL = dot(b,l);
  float dotTH = dot(t,h);
  float dotBH = dot(b,h);
  float dotLH = dot(l,h);
  float dotNV = material.dotNV;

  // Anisotropic parameters: at end ab are the roughness along the tangent and bitangent
  // to simplify materials, we derive them from a single roughness parameter
  // Kulla 2017, "Revisiting Physically Based Shading at Imageworks"
  float at = max(material.linearRoughness * (1.0 + material.anisotropy), MIN_LINEAR_ROUGHNESS);
  float ab = max(material.linearRoughness * (1.0 - material.anisotropy), MIN_LINEAR_ROUGHNESS);

  float D = D_GGX_Anisotropic(at, ab, dotTH, dotBH, dotNH);
  float V = V_SmithGGXCorrelated_Anisotropic(at, ab, dotTV, dotBV, dotTL, dotBL, dotNV, dotNL);
  vec3 F = F_Schlick(material.specularColor, dotLH);
  return F*(V*D);
}

// Ashikhmin 2007, "Distribution-based BRDFs"
float D_Ashikhmin(float linearRoughness, float dotNH) {
  float a2 = linearRoughness * linearRoughness;
  float cos2h = dotNH*dotNH;
  float sin2h = max(1.0-cos2h, 0.0078125); // 2^(-14/2), so sin2h^2 > 0 in fp16
  float sin4h = sin2h*sin2h;
  float cot2 = -cos2h / (a2*sin2h);
  return 1.0 / (PI * (4.0*a2+1.0)*sin4h) * (4.0*exp(cot2)+sin4h);
}

// Estevez and Kulla 2017, "Production Friendly Microfacet Sheen BRDF"
float D_Charlie(float linearRoughness, float dotNH) {
  float invAlpha = 1.0 / linearRoughness;
  float cos2h = dotNH * dotNH;
  float sin2h = max(1.0 - cos2h, 0.0078125); // 2^(-14/2), so sin2h^2 > 0 in fp16
  return (2.0 + invAlpha) * pow(sin2h, invAlpha*0.5) / (2.0*PI);
}

// Cook-Torrance
vec3 SpecularBRDF(const in IncidentLight directLight, 
  const in GeometricContext geometry, const in Material material,
  float dotNL, float dotNH, float dotVH) {

  if (material.anisotropy != 0.0) {
    return SpecularBRDF_Anisotropic(directLight, geometry, material, dotNL, dotNH, dotVH);
  }
  
  float D = D_GGX(material.linearRoughness, dotNH);
  // float V = V_SmithGGXCorrelated(material.linearRoughness,
  //   material.dotNV, dotNL);
  float V = V_SmithGGXCorrelated_Fast(material.linearRoughness,
    material.dotNV, dotNL);
  vec3 F = F_Schlick(material.specularColor, dotVH);
  return F*(V*D);
}

float SpecularBRDF_ClearCoat(const in IncidentLight directLight, 
  const in GeometricContext geometry, const in Material material, 
  float dotNH, float dotVH, float dotLH,
  out float Fcc) {
  
  float D = D_GGX(material.linearClearCoatRoughness, dotNH);
  float V = V_Keleman(dotLH);
  float F = F_SchlickF(0.04, 1.0, dotVH) * clearCoat;
  Fcc = F;
  return F*V*D;
}

// RenderEquations(RE)
void RE_Direct(const in IncidentLight directLight, const in GeometricContext geometry, const in Material material, inout ReflectedLight reflectedLight) {
  
  float dotNL = saturate(dot(geometry.normal,directLight.direction));
  vec3 irradiance = dotNL * directLight.color;

  vec3 H = normalize(directLight.direction + geometry.viewDir);
  float dotNH = saturate(dot(geometry.normal, H));
  float dotVH = saturate(dot(geometry.viewDir,H));
  float dotLH = saturate(dot(directLight.direction,H));
  
  // punctual light
  irradiance *= PI;
  
  vec3 Fd = irradiance * DiffuseBRDF(material.diffuseColor);
  vec3 Fr = irradiance * SpecularBRDF(directLight, geometry, material, dotNL, dotNH, dotVH);

  // clear coat
  float Fcc;
  vec3 Fc = irradiance * SpecularBRDF_ClearCoat(directLight, geometry, material, dotNH, dotVH, dotLH, Fcc);

  float attenuation = 1.0 - Fcc;
  float attenuation2 = attenuation * attenuation;
  reflectedLight.directDiffuse += Fd * attenuation;
  reflectedLight.directSpecular += Fr * attenuation2 * material.energyCompensation;
  reflectedLight.directSpecular += Fc;
  // reflectedLight.directDiffuse += Fd;
  // reflectedLight.directSpecular += Fr;
}

// IBLs
uniform samplerCube radianceMap;
uniform samplerCube irradianceMap;
uniform float indirectDiffuseIntensity;
uniform float indirectSpecularIntensity;

// [ Lazarov 2013 "Getting More Physical in Call of Duty: Black Ops II" ]
// Adaptation to fit our G term
// ref: https://www.unrealengine.com/blog/physically-based-shading-on-mobile - environmentBRDF for GGX on mobile
// BRDF_Specular_GGX_Environment
vec3 EnvBRDFApprox(vec3 specularColor, float roughness, float NoV) {
  const vec4 c0 = vec4(-1, -0.0275, -0.572, 0.022);
  const vec4 c1 = vec4(1, 0.0425, 1.04, -0.04 );
  vec4 r = roughness * c0 + c1;
  float a004 = min(r.x * r.x, exp2(-9.28 * NoV)) * r.x + r.y;
  vec2 AB = vec2(-1.04, 1.04) * a004 + r.zw;
  return specularColor * AB.x + AB.y;
}

// three.js (bsdfs.glsl)
// source: http://simonstechblog.blogspot.ca/2011/12/microfacet-brdf.html
float GGXRoughnessToBlinnExponent(const in float ggxRoughness) {
  return 2.0 / pow2(ggxRoughness + 0.0001) - 2.0;
}

float BlinnExponentToGGXRoughness(const in float blinnExponent) {
  return sqrt(2.0 / (blinnExponent + 2.0));
}

// taken from here: http://casual-effects.blogspot.ca/2011/08/plausible-environment-lighting-in-two.html
float getSpecularMipLevel(const in float blinnShininessExponent, const in int maxMipLevel) {
  float maxMipLevelScalar = float(maxMipLevel);
  float desiredMipLevel = maxMipLevelScalar - 0.79248 - 0.5 * log2(pow2(blinnShininessExponent)+1.0);
  
  // clamp to allowable LOD ranges
  return clamp(desiredMipLevel, 0.0, maxMipLevelScalar);
}

vec3 getLightProbeIndirectIrradiance(const in vec3 N, const in float blinnShininessExponent, const in int maxMipLevel) {
  vec3 worldNormal = inverseTransformDirection(N, viewMatrix);
  vec3 queryVec = vec3(-worldNormal.x, worldNormal.yz); //flip
  return PI * GammaToLinear(textureCube(irradianceMap, queryVec), float(GAMMA_FACTOR)).rgb;
}

vec3 getLightProbeIndirectRadiance(const in vec3 r, const in float blinnShininessExponent, const in int maxMipLevel) {
  vec3 reflectVec = inverseTransformDirection(r, viewMatrix);
  float specMipLevel = getSpecularMipLevel(blinnShininessExponent, maxMipLevel);
  vec3 queryVec = vec3(-reflectVec.x, reflectVec.yz); //flip
  return GammaToLinear(textureCubeLodEXT(radianceMap, queryVec, specMipLevel), float(GAMMA_FACTOR)).rgb;
}

void RE_Indirect(const in vec3 irradiance, const in vec3 radiance, 
  const in GeometricContext geometry, const in Material material, inout ReflectedLight reflectedLight) {

  vec3 Fd = irradiance * DiffuseBRDF(material.diffuseColor) * indirectDiffuseIntensity;
  vec3 Fr = radiance * EnvBRDFApprox(material.specularColor, material.specularRoughness, material.dotNV);

  // The clear coat layer assumes an IOR of 1.5 (4% reflectance)
  float Fc = F_SchlickF(0.04, 1.0, material.dotNV) * clearCoat;
  float attenuation = 1.0 - Fc;
  float attenuation2 = attenuation*attenuation;
  Fr *= attenuation2;
  Fr += radiance * EnvBRDFApprox(material.specularColor, material.clearCoatRoughness, material.dotNV) * Fc;
  Fd *= attenuation;

  Fd *= indirectDiffuseIntensity;
  Fr *= indirectSpecularIntensity;

  reflectedLight.indirectDiffuse  += Fd;
  reflectedLight.indirectSpecular += Fr;
}

//-------------------------------------------------------------------------
void PrepareMaterial(in GeometricContext geometry, inout Material material) {

  material.clearCoatRoughness = mix(MIN_ROUGHNESS, MAX_CLEAR_COAT_ROUGHNESS, clearCoatRoughness);
  material.linearClearCoatRoughness = material.clearCoatRoughness * material.clearCoatRoughness;

  material.specularRoughness = max(material.specularRoughness, material.clearCoatRoughness);
  material.linearRoughness = material.specularRoughness * material.specularRoughness;
  
  material.specularColor = mix(material.specularColor,
    f0ClearCoatToSurface(material.specularColor), clearCoat);

  material.dotNV = saturate(dot(geometry.normal,geometry.viewDir));

  // Prefiltered DFG term used for image-based lighting
  material.dfg = PrefilteredDFG(material.specularRoughness, material.dotNV);

  // Energy compensation for multiple scattering in a microfacet model
  // See "Multiple-Scattering Microfacet BSDFs with the Smith Model"
  material.energyCompensation = 1.0 + material.specularColor * (1.0 / material.dfg.y - 1.0);
  material.energyCompensation = mix(vec3(1.0), material.energyCompensation, energyCompensation);
  // material.energyCompensation = vec3(1.0);

  // Re-normalize post-interpolation values
  // material.tangentToWorld = mat3(
  //   normalize(vTangent), normalize(vBinormal), geometry.normal);
  
  // vec3 anisotropicDirection = vec3(1.0,0.0,0.0);
  // material.anisotropicT = normalize(material.tangentToWorld * anisotropicDirection);
  // material.anisotropicB = normalize(cross(material.tangentToWorld[2], material.anisotropicT));
  material.anisotropicT = normalize(vTangent);
  material.anisotropicB = normalize(vBinormal);
  material.anisotropy = anisotropy;
}

vec3 getSpecularDominantDirection(const vec3 n, const vec3 r, float linearRoughness) {
  float s = 1.0 - linearRoughness;
  return mix(n, r, s*(sqrt(s) + linearRoughness));
  // return r;
}

vec3 getReflectedVector(const in GeometricContext geometry, const in Material material) {
  vec3 r;
  // if (abs(material.anisotropy) >= 1e5) {
  if (abs(material.anisotropy) != 0.0) {
    vec3 anisotropyDirection = material.anisotropy >= 0.0 ? material.anisotropicB : material.anisotropicT;
    vec3 anisotropicT = cross(anisotropyDirection, geometry.viewDir);
    vec3 anisotropicN = cross(anisotropicT, anisotropyDirection);
    float bendFactor = abs(material.anisotropy) * saturate(5.0 * material.specularRoughness);
    vec3 bentNormal = normalize(mix(geometry.normal, anisotropicN, bendFactor));
    r = reflect(-geometry.viewDir, bentNormal);
  }
  else {
    r = reflect(-geometry.viewDir, geometry.normal);
  }
  return getSpecularDominantDirection(geometry.normal, r, material.linearRoughness);
}

void main() {
  GeometricContext geometry;
  geometry.position = -vViewPosition;
  geometry.normal = normalize(vNormal);
  geometry.viewDir = normalize(vViewPosition);

  vec3 baseColor = GammaToLinear(vec4(albedo,1.0), float(GAMMA_FACTOR)).xyz;
  
  Material material;
  material.diffuseColor = mix(baseColor, vec3(0.0), metallic);
  // Assumes an interface from air to an IOR of 1.5 for dielectrics
  material.specularColor = mix(vec3(0.04), baseColor, metallic);

  // Clamp the roughness to a minimum value to avoid divisions by 0 in the lighting code
  material.specularRoughness = clamp(roughness, MIN_ROUGHNESS, 1.0);

  PrepareMaterial(geometry, material);
  
  // Direct lighting
  
  ReflectedLight reflectedLight = ReflectedLight(vec3(0.0), vec3(0.0), vec3(0.0), vec3(0.0));
  vec3 emissive = vec3(0.0);
  float opacity = 1.0;
  
  IncidentLight directLight;
  directLight.direction = dirLightDir;
  directLight.color = dirLightColor;
  directLight.visible = true;
  RE_Direct(directLight, geometry, material, reflectedLight);

  // Indirect lighting
  float blinnExponent = GGXRoughnessToBlinnExponent(material.specularRoughness);
  vec3 irradiance = getLightProbeIndirectIrradiance(geometry.normal, blinnExponent, 8);
  // irradiance = getLightProbeIndirectIrradianceSH(geometry.normal);

  vec3 r = getReflectedVector(geometry, material);
  vec3 radiance = getLightProbeIndirectRadiance(r, blinnExponent, 8);
  RE_Indirect(irradiance, radiance, geometry, material, reflectedLight);

  vec3 outgoingLight = emissive + reflectedLight.directDiffuse + reflectedLight.directSpecular + reflectedLight.indirectDiffuse + reflectedLight.indirectSpecular;

  // outgoingLight = vec3(clearCoat);
  // outgoingLight = vec3(clearCoatRoughness);
  // outgoingLight = material.specularColor;
  // outgoingLight = vec3(material.specularRoughness);
  // outgoingLight = vec3(material.dfg.xy, 0.0);
  // outgoingLight = vec3(1.0-material.dfg.y);
  // outgoingLight = vec3(1.0 / max(material.dfg.y,EPSILON)-1.0);
  // outgoingLight = material.energyCompensation;
  // outgoingLight = heatmap(material.energyCompensation.z);
  // outgoingLight = heatmap(luminance(material.energyCompensation));
  // outgoingLight = reflectedLight.directDiffuse;
  // outgoingLight = reflectedLight.directSpecular;
  // outgoingLight = reflectedLight.indirectDiffuse;
  // outgoingLight = reflectedLight.indirectSpecular;
  // outgoingLight = emissive;

  outgoingLight = Tonemap_ACES(outgoingLight);
  outgoingLight = LinearToGamma(vec4(outgoingLight,1.0), float(GAMMA_FACTOR)).xyz;
  
  gl_FragColor = vec4(outgoingLight, opacity);
}
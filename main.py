from lib.c3_sdk_python_0_0_2 import sdk
from lib.eyescream.dataset import generate_dataset as gd
from PIL import Image
import io
import os

c3 = None
PillowImageRequired = Exception("pillow image is required")
InvalidImage = Exception("invalid image")
C3Required = Exception("c3 cannot be None")
TrainingFailed = Exception("model training failed")
standardImgFormat = "JPEG"
tmpDir = "tmp"
libDir = "lib"
inputRelPath = tmpDir + os.path.sep + "input"
augRelPath = tmpDir + os.path.sep + "aug_64x64"
unaugRelPath = tmpDir + os.path.sep + "unaug_64x64"
networkRelPath = tmpDir + os.path.sep + "network"
scriptFileRelPath = libDir + os.path.sep + "eyescream" + os.path.sep + "train.lua"
inputAbsPath = os.path.dirname(os.path.abspath(__file__)) + os.path.sep + inputRelPath
augAbsPath = os.path.dirname(os.path.abspath(__file__)) + os.path.sep + augRelPath
unaugAbsPath = os.path.dirname(os.path.abspath(__file__)) + os.path.sep + unaugRelPath
networkAbsPath = os.path.dirname(os.path.abspath(__file__)) + os.path.sep + networkRelPath
oldNetworkAbsPath = networkAbsPath + os.path.sep + "old.net"
newNetworkAbsPath = networkAbsPath + os.path.sep + "adversarial.net"
scriptFileAbsPath = os.path.dirname(os.path.abspath(__file__)) + os.path.sep + scriptFileRelPath
augImagesKey = "aug_images"
networkKey = "network"

def main():
    global c3
    c3 = sdk.NewC3()
    c3.registerMethod("acceptImage", acceptImage)
    initState()
    c3.serve()

def initState():
    global c3
    if c3 == None:
        print("c3 is none")
        raise C3Required

    if not os.path.exists(inputRelPath):
        os.makedirs(inputRelPath)
    if not os.path.exists(augRelPath):
        os.makedirs(augRelPath)
    if not os.path.exists(unaugRelPath):
        os.makedirs(unaugRelPath)
    if not os.path.exists(networkRelPath):
        os.makedirs(networkRelPath)
        
    if augImagesKey in c3.state:
        for idx in range(len(c3.state[augImagesKey])):
            b = c3.state[augImagesKey][idx]
            im = imageFromBytes(b)
            im.save(augAbsPath + os.path.sep + idx + standardImgFormat)

    network = bytearray()
    if networkKey in c3.state:
        network = c3.state[networkKey]

    writeBytesToFile(network, oldNetworkAbsPath) 

def writeBytesToFile(b, fileName):
    f = open(fileName, 'wb+')
    f.write(b)
    f.close()

# http://www.codecodex.com/wiki/Read_a_file_into_a_byte_array#Python
def readBytesFromFile(filename):
    return open(filename, "rb+").read()

def imageFromBytes(b):
    im = Image.open(b)
    return im

def imageToBytes(name, ext, img):
    b = io.BytesIO()
    img.save(b, format=ext)
    b.name = name + "." + ext
    b.seek(0)

    return b

def acceptImage(img):
    if img == None:
        print("pillow image is required")
        raise PillowImageRequired

    try:
        if not img.verify():
            print("image failed to verify")
            raise InvalidImage

    except Exception as err:
        print("invalid img", err)
        raise InvalidImage

    img.save(inputAbsPath + os.path.sep + "input." + standardImgFormat, format=standardImgFormat)

    # augment the input image and save it to disk
    gd.gen(inputAbsPath, augAbsPath, unaugAbsPath)

    # run an epoch of the model and save the weights
    # note: it's not ideal to run an epoch after each image is added \
    #       but this code is for example purposes, only...
    result = subprocess.run([scriptFileAbsPath, "--network", oldNetworkAbsPath, "--save", networkAbsPath])
    if result.returncode != 0:
        print("Preprocess failed: ", result.stderr)
        raise TrainingFailed

    gatherState()

def gatherState():
    global c3
    c3.state[networkKey] = open(newNetworkAbsPath, "rb+").read()
    
    c3.state[augImagesKey] = []
    # r=root, d=directories, f=files
    for r, d, f in os.walk(augAbsPath):
        for file in f:
            if "." + standardImgFormat in file:
                c3.state[augImagesKey].append(readBytesFromFile(os.path.join(r, file)))

if __name__ == "__main__":
    main()

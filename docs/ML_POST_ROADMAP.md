# Post-ML Roadmap

## Goal

Rank the next ML workloads from easiest to hardest after you have:

- dot product
- MAC
- vector lanes
- matrix support

## Easiest to hardest

### 1. Linear regression

Why first:

- mostly dot products and scalar math
- small code size
- easy to verify

### 2. Logistic regression

Why next:

- adds activation functions
- still mostly dot products
- good first classifier

### 3. Perceptron / small MLP

Why next:

- built from matrix-vector multiply
- introduces hidden layers
- still manageable on small dimensions

### 4. KNN

Why next:

- uses distance calculations heavily
- benefits from vectorized subtract/square/reduce
- memory/search cost is still moderate at small scale

### 5. K-means clustering

Why next:

- repeated distance + centroid update loops
- good fit for MAC and reduction
- more iteration/state than KNN

### 6. Small CNN

Why next:

- convolution is basically many MACs
- very good fit for vector and matrix hardware
- more data movement and tiling complexity

### 7. Tiny RNN / GRU

Why later:

- recurrent state makes execution harder
- still depends on MAC and matrix ops
- control flow is more complex than CNNs

### 8. Tiny Transformer / Attention

Why hardest:

- heavy matrix multiply use
- needs strong memory bandwidth
- attention is compute- and bandwidth-intensive

## Best first demos

If you want quick wins, do these in order:

1. dot product
2. linear regression
3. KNN distance kernel
4. small MLP
5. small CNN

## Practical note

For this CPU, **CNNs are a better hardware fit than KNN** because they benefit more from MAC/vector/matrix acceleration.

KNN is still useful, but it is more memory/search bound.

